// Port of photocraft-algo (crates/algo/src/matting.rs, matting/brush.rs, matting/morphology/tests.rs tests), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import Testing
@testable import PCAlgo
import PCFoundation

enum MatTest {
    /// Horizontal blend from `a` (left) to `b` (right) across a Gaussian-blurred edge at x = 40;
    /// returns the image and the true foreground fraction per column.
    static func blurredEdge(_ w: Int, _ h: Int, sigma: Float) -> (SegmentRGBImage, [Float]) {
        let a = SIMD3<Float>(0.9, 0.8, 0.2), b = SIMD3<Float>(0.1, 0.2, 0.6)
        func erf(_ x: Float) -> Float {
            let t = 1 / (1 + 0.327_591_1 * abs(x))
            let y = 1 - (((((1.061_405_4 * t - 1.453_152_1) * t) + 1.421_413_7) * t - 0.284_496_74) * t + 0.254_829_6) * t * expf(-x * x)
            return x >= 0 ? y : -y
        }
        let alpha = (0..<w).map { x in 0.5 * (1 - erf((Float(x) + 0.5 - 40) / (sigma * Float(2).squareRoot()))) }
        let img = SegmentRGBImage(w: w, h: h) { x, _ in
            SIMD3(a.x * alpha[x] + b.x * (1 - alpha[x]), a.y * alpha[x] + b.y * (1 - alpha[x]), a.z * alpha[x] + b.z * (1 - alpha[x]))
        }
        return (img, alpha)
    }

    static func rect(_ w: Int, _ h: Int) -> PixelRect { PixelRect(x0: 0, y0: 0, x1: Int32(w), y1: Int32(h)) }

    static func bits(_ v: [Float]) -> [UInt32] { v.map(\.bitPattern) }
}

struct SegmentMattingTests {
    // MARK: matting.rs

    @Test func maxSquareMatchesNaive() {
        let (w, h) = (17, 11)
        let src = (0..<(w * h)).map { Float(($0 * 37) % 23) }
        for r in [1, 2, 5] {
            for isMax in [true, false] {
                let fast = Matting.maxSquare(src, w, h, r, isMax)
                for y in 0..<h {
                    for x in 0..<w {
                        var v: Float = isMax ? -.greatestFiniteMagnitude : .greatestFiniteMagnitude
                        for yy in max(y - r, 0)..<min(y + r + 1, h) {
                            for xx in max(x - r, 0)..<min(x + r + 1, w) {
                                v = isMax ? Float.maximum(v, src[yy * w + xx]) : Float.minimum(v, src[yy * w + xx])
                            }
                        }
                        #expect(fast[y * w + x] == v, "r=\(r) max=\(isMax) (\(x),\(y))")
                    }
                }
            }
        }
    }

    @Test func boxMeanMatchesNaive() {
        let (w, h) = (13, 9)
        let src = (0..<(w * h)).map { Float(($0 * 7) % 11) }
        let fast = Matting.boxMean(src, w: w, h: h, r: 2)
        var worst: Float = 0
        for y in 0..<h {
            for x in 0..<w {
                var s: Float = 0, n: Float = 0
                for yy in max(y - 2, 0)..<min(y + 3, h) {
                    for xx in max(x - 2, 0)..<min(x + 3, w) { s += src[yy * w + xx]; n += 1 }
                }
                worst = max(worst, abs(fast[y * w + x] - s / n))
            }
        }
        #expect(worst < 1e-4)
    }

    @Test func guidedFilterMattingSoftensBlurredEdge() {
        let (w, h) = (80, 20)
        let (img, truth) = MatTest.blurredEdge(w, h, sigma: 3)
        let m: [Float] = (0..<(w * h)).map { $0 % w < 40 ? 1 : 0 }
        let a = Matting.refineBuffer(img, m, w: w, h: h, RefineParams(radius: 10))
        let row = Array(a[(10 * w)..<(11 * w)])
        let soft = row.filter { $0 > 0.05 && $0 < 0.95 }.count
        #expect(soft >= 6, "only \(soft) soft pixels: \(row)")
        for x in 0..<w {
            #expect(abs(row[x] - truth[x]) < 0.12, "x=\(x): \(row[x]) vs \(truth[x])")
            if x > 0 { #expect(row[x] <= row[x - 1] + 0.02, "not monotone at \(x)") }
        }
        // Outside the band the mask is untouched.
        #expect(row[5] == 1)
        #expect(row[75] == 0)
        // Smart radius keeps a sharp edge sharp.
        let sharp = SegmentRGBImage(w: w, h: h) { x, _ in x < 40 ? SIMD3(0.9, 0.8, 0.2) : SIMD3(0.1, 0.2, 0.6) }
        let s = Matting.refineBuffer(sharp, m, w: w, h: h, RefineParams(radius: 10, smartRadius: true))
        let soft2 = s[(10 * w)..<(11 * w)].filter { $0 > 0.05 && $0 < 0.95 }.count
        #expect(soft2 <= 2, "sharp edge became soft: \(soft2)")
    }

    @Test func featherContrastAndShift() {
        let (w, h) = (60, 10)
        let m: [Float] = (0..<(w * h)).map { $0 % w < 30 ? 1 : 0 }
        let f = Matting.refineBuffer(nil, m, w: w, h: h, RefineParams(feather: 6))
        #expect(f[5 * w + 29] > 0.5 && f[5 * w + 29] < 0.8 && f[5 * w + 31] > 0.1)
        let c = Matting.refineBuffer(nil, f, w: w, h: h, RefineParams(contrast: 100))
        #expect(c[5 * w + 29] == 1 && c[5 * w + 31] == 0)
        let grown = Matting.refineBuffer(nil, m, w: w, h: h, RefineParams(shiftEdge: 100))
        #expect(grown[5 * w + 33] == 1)
        #expect(grown[5 * w + 34] == 0)
        let shrunk = Matting.refineBuffer(nil, m, w: w, h: h, RefineParams(shiftEdge: -50))
        #expect(shrunk[5 * w + 27] == 1)
        #expect(shrunk[5 * w + 28] == 0)
        // Radius 0 scales 100% to 4 px, so 12.5% is half a pixel and 25% is one pixel.
        let half = Matting.refineBuffer(nil, m, w: w, h: h, RefineParams(shiftEdge: 12.5))
        let one = Matting.refineBuffer(nil, m, w: w, h: h, RefineParams(shiftEdge: 25))
        #expect(m[5 * w + 30] == 0)
        #expect(abs(half[5 * w + 30] - 0.5) < 0.02, "half pixel \(half[5 * w + 30])")
        #expect(one[5 * w + 30] == 1)
        #expect(half[5 * w + 31] == 0, "the blend must not jump a second pixel")
        let pulled = Matting.refineBuffer(nil, m, w: w, h: h, RefineParams(shiftEdge: -12.5))
        #expect(abs(pulled[5 * w + 29] - 0.5) < 0.02, "half-pixel contract \(pulled[5 * w + 29])")
        let sm = Matting.refineBuffer(nil, m, w: w, h: h, RefineParams(smooth: 50))
        #expect(sm[5 * w + 10] == 1 && sm[5 * w + 50] == 0)
    }

    @Test func refineMaskTilesMatchSingleBuffer() throws {
        // Tiled processing gives the same result as processing the whole image at once.
        let (w, h) = (600, 300)
        let (img, _) = MatTest.blurredEdge(w, h, sigma: 2)
        let s = ImageSegmentSampler(img, origin: (0, 0))
        var mask = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let dx = Float(x) - 40, dy = Float(y) - 150
                mask[y * w + x] = dx * dx * 0.05 + dy * dy < 120 * 120 || x < 40 ? 255 : 0
            }
        }
        let reg = SelectionRegion(bbox: MatTest.rect(w, h), mask: mask)
        let p = RefineParams(radius: 6, feather: 2, contrast: 10)
        let out = try #require(Matting.refineMask(s, mask: Matting.regionReader(reg), content: reg.bbox, canvas: reg.bbox, p))
        let whole = reg.mask.map { Float($0) / 255 }
        let full = Matting.refineBuffer(img, whole, w: w, h: h, p)
        var maxd: Float = 0
        for y in 0..<h { for x in 0..<w { maxd = max(maxd, abs(out.at(Int32(x), Int32(y)) - full[y * w + x])) } }
        #expect(maxd <= 1.5 / 255, "tiles differ by \(maxd)")
    }

    @Test func decontaminateAndMaskedCopyAnyDepth() {
        for sample in [SampleType.u8, .u16, .f32] {
            let fmt = PixelFormat.rgba8.with(sample: sample)
            var s = Surface(format: fmt)
            // Foreground red on the left, background blue on the right; fringe pixel at x = 10 is a mix.
            s.fill(PixelRect(x0: 0, y0: 0, x1: 10, y1: 8), with: [1, 0, 0, 1])
            s.fill(PixelRect(x0: 10, y0: 0, x1: 20, y1: 8), with: [0.5, 0, 0.5, 1])
            s.fill(PixelRect(x0: 11, y0: 0, x1: 20, y1: 8), with: [0, 0, 1, 1])
            let mask: [UInt8] = (0..<(20 * 8)).map { i in i % 20 < 10 ? 255 : (i % 20 == 10 ? 128 : 0) }
            let a = SelectionRegion(bbox: PixelRect(x0: 0, y0: 0, x1: 20, y1: 8), mask: mask)
            let d = Matting.decontaminate(s, alpha: a, radius: 3, amount: 100)
            let p = d.pixel(x: 10, y: 4)
            #expect(p[0] > 0.9 && p[2] < 0.1, "\(sample): \(p)")
            #expect(d.pixel(x: 15, y: 4) == s.pixel(x: 15, y: 4))
            let c = Matting.maskedCopy(d, alpha: a)
            #expect(c.format == fmt)
            #expect(abs(c.pixel(x: 10, y: 4)[3] - 128.0 / 255) < 0.01)
            #expect(c.pixel(x: 15, y: 4)[3] == 0)
            #expect(c.pixel(x: 3, y: 3)[0] == 1)
        }
        // Sources without alpha gain an alpha channel.
        var g = Surface(format: .gray8)
        g.fill(PixelRect(x0: 0, y0: 0, x1: 4, y1: 4), with: [0.5])
        let a = SelectionRegion(bbox: PixelRect(x0: 0, y0: 0, x1: 2, y1: 4), mask: [UInt8](repeating: 255, count: 8))
        let c = Matting.maskedCopy(g, alpha: a)
        #expect(c.format == .graya8)
        #expect(c.pixel(x: 3, y: 1)[1] == 0)
        #expect(abs(c.pixel(x: 1, y: 1)[0] - 0.5) < 0.01 && c.pixel(x: 1, y: 1)[1] == 1)
    }

    // MARK: matting/brush.rs

    /// Strands of the subject's colour (every 4th column from x = 60) beyond the selection's edge
    /// at x = 40: brushing over them adds them, Alt-brushing the edge keeps it as it was.
    @Test func brushPicksUpStrandsBeyondTheBandAndRestoresTheEdge() throws {
        let (w, h) = (120, 60)
        let fg = SIMD3<Float>(0.9, 0.7, 0.2), bg = SIMD3<Float>(0.1, 0.3, 0.8)
        func strand(_ x: Int) -> Bool { x < 40 || ((60..<84).contains(x) && x % 4 == 0) }
        let img = SegmentRGBImage(w: w, h: h) { x, _ in strand(x) ? fg : bg }
        let s = ImageSegmentSampler(img, origin: (0, 0))
        let canvas = MatTest.rect(w, h)
        let reg = SelectionRegion(bbox: canvas, mask: (0..<(w * h)).map { $0 % w < 40 ? 255 : 0 })
        let p = RefineParams(radius: 4)
        func refine(_ strokes: [EdgeStroke]) throws -> SelectionRegion {
            let brush = EdgeBrush(strokes, canvas: canvas)
            return try #require(Matting.refineMaskBrushed(s, mask: Matting.regionReader(reg), content: reg.bbox, canvas: canvas, p, brush: brush))
        }
        let plain = try refine([])
        #expect(plain.at(64, 30) < 0.01, "the band alone stops short of the strands")
        let overStrands = EdgeStroke(points: [SIMD2(70, 10), SIMD2(70, 50)], size: 30, add: true)
        let brushed = try refine([overStrands])
        #expect(brushed.at(64, 30) > 0.9 && brushed.at(72, 30) > 0.9, "strands added: \(brushed.at(64, 30))")
        #expect(brushed.at(66, 30) < 0.1, "the background between them stays out: \(brushed.at(66, 30))")
        #expect(brushed.at(20, 30) > 0.99 && brushed.at(100, 30) < 0.01, "unpainted areas keep the refined selection")
        // Restoring paints the refinement out: with Shift Edge 0 the edge is the original one.
        let soft = RefineParams(radius: 4, feather: 0)
        let blurred = SegmentRGBImage(w: w, h: h) { x, _ in
            let t = clampf((Float(x) - 36) / 8, 0, 1)
            return fg * (1 - t) + bg * t
        }
        let sb = ImageSegmentSampler(blurred, origin: (0, 0))
        let refined = try #require(Matting.refineMaskBrushed(sb, mask: Matting.regionReader(reg), content: reg.bbox, canvas: canvas, soft, brush: nil))
        #expect(refined.at(41, 30) > 0.1, "the band softens the blurred edge")
        let restore = [EdgeStroke(points: [SIMD2(40, 0), SIMD2(40, 60)], size: 20, add: false)]
        let restored = try #require(Matting.refineMaskBrushed(sb, mask: Matting.regionReader(reg), content: reg.bbox, canvas: canvas, soft,
                                                              brush: EdgeBrush(restore, canvas: canvas)))
        #expect(restored.at(41, 30) < 0.01 && restored.at(38, 30) > 0.99, "the original edge is back")
    }

    @Test func strokesPaintInOrderAndClipToTheCanvas() throws {
        let canvas = PixelRect(x0: 0, y0: 0, x1: 100, y1: 50)
        let add = EdgeStroke(points: [SIMD2(10, 25), SIMD2(90, 25)], size: 10, add: true)
        let b = try #require(EdgeBrush([add], canvas: canvas))
        #expect(b.at(50, 25) > 0.99 && b.at(50, 40) == 0)
        #expect(b.window == 10)
        // A later subtract stroke paints over the add.
        let sub = EdgeStroke(points: [SIMD2(50, 25)], size: 20, add: false)
        let b2 = try #require(EdgeBrush([add, sub], canvas: canvas))
        #expect(b2.at(50, 25) < -0.99 && b2.at(20, 25) > 0.99)
        // Off the canvas, non-finite or empty strokes paint nothing.
        let off = EdgeStroke(points: [SIMD2(-500, -500)], size: 10, add: true)
        let nan = EdgeStroke(points: [SIMD2(.nan, 3)], size: 10, add: true)
        let empty = EdgeStroke(points: [], size: 10, add: true)
        #expect(EdgeBrush([off, nan, empty], canvas: canvas) == nil)
    }

    // MARK: matting/morphology

    @Test func everySmallBinaryMaskMatchesRepeatedOctagons() {
        var failures = 0
        for (w, h) in [(1, 1), (1, 7), (7, 1), (2, 3), (3, 3), (4, 3)] {
            for bits in 0..<(1 << (w * h)) {
                let src = (0..<(w * h)).map { Float((bits >> $0) & 1) }
                for r in [0, 1, 2, 3, 4, 5, 7, 10, 13] {
                    for grow in [false, true] where Matting.morph(src, w: w, h: h, r: r, grow: grow) != SegmentKit.morphRepeated(src, w, h, r, grow) {
                        failures += 1
                        if failures < 5 { Issue.record("\(w)x\(h) bits=\(bits) r=\(r) grow=\(grow)") }
                    }
                }
            }
        }
        #expect(failures == 0)
    }

    @Test func grayAndHDRValuesMatchAtEdgesAndEveryRadius() {
        for (w, h) in [(2, 29), (29, 2), (37, 29), (1, 51), (51, 1)] {
            for depth in [8, 16, 32] {
                let src: [Float] = (0..<(w * h)).map { i in
                    let v = Float((i * 101 + i / w * 37) % 251) / 250
                    switch depth {
                    case 8: return (v * 255).rounded() / 255
                    case 16: return (v * 65535).rounded() / 65535
                    default: return v * 4 - 1
                    }
                }
                for r in 0...65 {
                    for grow in [false, true] {
                        #expect(Matting.morph(src, w: w, h: h, r: r, grow: grow) == SegmentKit.morphRepeated(src, w, h, r, grow),
                                "\(w)x\(h) depth=\(depth) r=\(r) grow=\(grow)")
                    }
                }
            }
        }
    }

    @Test func impulsesMatchTheClosedOctagonalFootprint() {
        let (w, h) = (97, 83)
        var failures = 0
        for (sx, sy) in [(0, 0), (0, 41), (48, 41), (96, 82), (5, 79)] {
            for r in 1...65 {
                for grow in [true, false] {
                    var src = [Float](repeating: grow ? 0 : 1, count: w * h)
                    src[sy * w + sx] = grow ? 1 : 0
                    let out = Matting.morph(src, w: w, h: h, r: r, grow: grow)
                    let a = r / 2 + r % 2, b = r / 2
                    for y in 0..<h {
                        for x in 0..<w {
                            let affected = max(abs(x - sx) - a, 0) + max(abs(y - sy) - a, 0) <= b
                            let expected: Float = affected == grow ? 1 : 0
                            if out[y * w + x] != expected {
                                failures += 1
                                if failures < 5 { Issue.record("seed \(sx),\(sy) r=\(r) grow=\(grow) at \(x),\(y)") }
                            }
                        }
                    }
                }
            }
        }
        #expect(failures == 0)
    }

    @Test func exceptionalFloatsKeepTheOldVisitationOrder() {
        let (w, h) = (13, 9)
        for special in [Float(bitPattern: 0x7fc0_0001), -.infinity, .infinity, -0.0] {
            let src = (0..<(w * h)).map { i in i % 7 == 0 ? special : Float(i % 11) / 10 }
            for r in [1, 3, 4, 17, 64] {
                for grow in [false, true] {
                    #expect(MatTest.bits(Matting.morph(src, w: w, h: h, r: r, grow: grow)) == MatTest.bits(SegmentKit.morphRepeated(src, w, h, r, grow)))
                }
            }
        }
        let src = [Float](repeating: Float(bitPattern: 0x7fc0_0002), count: w * h)
        #expect(MatTest.bits(Matting.morph(src, w: w, h: h, r: 17, grow: true)) == MatTest.bits(src))
    }

    @Test func invalidSizesAndLargeRadiiAreBounded() {
        #expect(Matting.morph([], w: .max, h: 2, r: 3, grow: true).isEmpty)
        #expect(Matting.morph([0], w: 2, h: 2, r: 3, grow: true).isEmpty)
        #expect(Matting.morph([], w: 0, h: 5, r: .max, grow: true) == [])
        #expect(Matting.morph([0, 0.5, 1, 0.1], w: 2, h: 2, r: .max, grow: true) == [1, 1, 1, 1])
        #expect(Matting.morph([0, 0.5, 1, 0.1, 42], w: 2, h: 2, r: 5, grow: true) == [1, 1, 1, 1, 42])
        // Constant masks (with a sample past w × h) come back unchanged (photocraft checks this on
        // 1031 × 1021 to cover its bounded tiles; the port has one dense path, so a smaller mask).
        let (w, h) = (131, 127)
        for value: Float in [0, 0.5, 1, .infinity, -.infinity] {
            var src = [Float](repeating: value, count: w * h)
            src.append(42)
            for grow in [true, false] { #expect(Matting.morph(src, w: w, h: h, r: 64, grow: grow) == src) }
        }
    }

    @Test func saturatedRadiusDoesNotPadAThinAxisToTheLongAxis() {
        let (w, h) = (2, 30001)
        let src = (0..<(w * h)).map { Float($0 % 251) }
        #expect(Matting.morph(src, w: w, h: h, r: .max, grow: true) == [Float](repeating: 250, count: w * h))
        #expect(Matting.morph(src, w: w, h: h, r: .max, grow: false) == [Float](repeating: 0, count: w * h))
    }

    @Test func shiftedTilesMatchAWholeMaskAtCanvasEdges() throws {
        let (w, h) = (611, 317)
        let img = SegmentRGBImage(w: w, h: h) { _, _ in SIMD3(repeating: 0.5) }
        let sampler = ImageSegmentSampler(img, origin: (0, 0))
        let mask: [UInt8] = (0..<(w * h)).map { i in (i % w < 63 && i / w < 191) || (i % w > 280 && i / w > 171) ? 255 : 0 }
        let rect = MatTest.rect(w, h)
        let region = SelectionRegion(bbox: rect, mask: mask)
        let input = region.mask.map { Float($0) / 255 }
        for shift: Float in [-100, -51, 51, 100] {
            // Constant guide keeps this check independent of image detail.
            let p = RefineParams(radius: 32, shiftEdge: shift)
            let whole = Matting.refineBuffer(img, input, w: w, h: h, p)
            let tiled = try #require(Matting.refineMask(sampler, mask: Matting.regionReader(region), content: rect, canvas: rect, p))
            var worst: Float = 0
            for y in 0..<h { for x in 0..<w { worst = max(worst, abs(tiled.at(Int32(x), Int32(y)) - whole[y * w + x])) } }
            #expect(worst <= 1.5 / 255, "shift=\(shift): \(worst)")
        }
    }
}
