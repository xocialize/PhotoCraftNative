// Port of photocraft-algo (crates/algo/src/sharpen.rs, other.rs, other2.rs tests), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Testing
@testable import PCAlgo
import PCFoundation

@Suite struct SharpenTests {
    @Test func unsharpParity() throws {
        var w: Float = 0
        for (a, r, t): (Float, Float, Float) in [(100, 1, 0), (250, 3.5, 4), (50, 0.3, 0), (500, 12, 10)] {
            w = max(w, try Parity.checkVariants(UnsharpMask(amount: a, radius: r, threshold: t)))
        }
        ParityLog.record("UnsharpMask", w)
    }

    @Test func smartSharpenParity() throws {
        var w: Float = 0
        for (a, r, nr): (Float, Float, Float) in [(100, 1, 10), (300, 4, 60), (80, 0.5, 100)] {
            w = max(w, try Parity.checkVariants(SmartSharpen(amount: a, radius: r, reduceNoise: nr)))
        }
        ParityLog.record("SmartSharpen", w)
    }

    @Test func highPassParity() throws {
        var w: Float = 0
        for r: Float in [0.5, 3, 10] { w = max(w, try Parity.checkVariants(HighPass(radius: r))) }
        ParityLog.record("HighPass", w)
    }

    @Test func presetsParity() throws {
        var w: Float = 0
        for s in SharpenPreset.Strength.allCases { w = max(w, try Parity.checkVariants(SharpenPreset(s))) }
        ParityLog.record("Sharpen/SharpenMore/SharpenEdges", w)
    }

    @Test func highPassOfFlatIsMidGray() {
        let r = PixelRect(x: 0, y: 0, width: 12, height: 12)
        let img = FloatImage(rect: r.outset(by: 10), channels: 1, data: [Float](repeating: 0.3, count: r.outset(by: 10).area))
        let out = HighPass(radius: 2).cpu(img, out: r, ctx: FilterContext(bounds: r, mode: .grayscale, alpha: false))
        #expect(out.data.allSatisfy { abs($0 - 0.5) < 1e-5 })
    }
}

@Suite struct OtherTests {
    /// The square window scanned directly (photocraft `min_max_direct`).
    func minMaxDirect(_ src: FloatImage, _ out: PixelRect, _ r: Int32, _ isMax: Bool) -> FloatImage {
        var res = FloatImage(rect: out, channels: src.channels)
        for y in out.y0..<out.y1 {
            for x in out.x0..<out.x1 {
                for c in 0..<src.channels {
                    var m: Float = isMax ? -.greatestFiniteMagnitude : .greatestFiniteMagnitude
                    for yy in (y - r)...(y + r) { for xx in (x - r)...(x + r) { let v = src.get(xx, yy, c); m = isMax ? max(m, v) : min(m, v) } }
                    res.data[res.index(x: x, y: y) + c] = m
                }
            }
        }
        return res
    }

    @Test func squareMinMaxMatchesDirectWindowExactly() {
        let srcRect = PixelRect(x0: -12, y0: -9, x1: 37, y1: 30)
        let img = TestImage.make(srcRect, channels: 4, alpha: true, seed: 9, eightBit: false)
        for out in [PixelRect(x0: 0, y0: 0, x1: 25, y1: 21), PixelRect(x0: -14, y0: -3, x1: 3, y1: 40)] {
            for r: Int32 in [1, 2, 3, 7, 20] {
                for isMax in [false, true] {
                    let fast = OtherKit.minMax(img, out, Float(r), isMax)
                    #expect(fast == minMaxDirect(img, out, r, isMax), "r \(r) max \(isMax) out \(out)")
                }
            }
        }
    }

    @Test func roundHalfWidthKeepsExactSquares() {
        #expect(OtherKit.roundHalfWidth(5, 3) == 4)
        #expect(OtherKit.roundHalfWidth(5, 5) == 0)
    }

    @Test func minMaxParity() throws {
        var w: Float = 0
        for r: Float in [1, 2.6, 6] {
            for p in Preserve.allCases {
                w = max(w, try Parity.checkVariants(Minimum(radius: r, preserve: p)))
                w = max(w, try Parity.checkVariants(Maximum(radius: r, preserve: p)))
            }
        }
        #expect(w == 0, "min/max are exact")
        ParityLog.record("Minimum/Maximum", w)
    }

    @Test func offsetParity() throws {
        var w: Float = 0
        for u in UndefinedAreas.allCases {
            for (dx, dy): (Int32, Int32) in [(5, -3), (-70, 13), (0, 0)] {
                w = max(w, try Parity.checkVariants(Offset(horizontal: dx, vertical: dy, undefined: u)))
            }
        }
        #expect(w == 0)
        ParityLog.record("Offset", w)
    }

    @Test func offsetWrapsAroundBounds() {
        let b = PixelRect(x: 0, y: 0, width: 4, height: 1)
        let img = FloatImage(rect: b, channels: 1, data: [0, 1, 2, 3])
        let out = Offset(horizontal: 1, vertical: 0, undefined: .wrap).cpu(img, out: b, ctx: FilterContext(bounds: b, mode: .grayscale, alpha: false))
        #expect(out.data == [3, 0, 1, 2])
    }

    @Test func customParity() throws {
        var w: Float = 0
        let sharpen: [Float] = [0, 0, 0, 0, 0, 0, 0, -1, 0, 0, 0, -1, 5, -1, 0, 0, 0, -1, 0, 0, 0, 0, 0, 0, 0]
        let emboss: [Float] = [-2, -1, 0, 0, 0, -1, 1, 1, 0, 0, 0, 1, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3]
        for (k, s, o): ([Float], Float, Float) in [(sharpen, 1, 0), (emboss, 3, 40), ([1, 2, 3], 0, -10), ([], 1, 0)] {
            w = max(w, try Parity.checkVariants(CustomKernel(kernel: k, scale: s, offset: o)))
        }
        ParityLog.record("Custom", w)
    }
}
