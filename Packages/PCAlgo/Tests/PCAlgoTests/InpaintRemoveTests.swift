// Port of photocraft-algo (crates/algo/src/remove.rs tests, nonlocal.rs tests), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import Testing
@testable import PCAlgo
import PCFoundation

@Suite struct InpaintRemoveTests {
    typealias K = InpaintKit

    static func grid(_ w: Int, _ h: Int, _ f: (Int, Int) -> Bool) -> [Bool] { (0..<(w * h)).map { f($0 % w, $0 / w) } }

    // MARK: photocraft remove.rs

    @Test func aRingClosesIntoADiscAndAnOpenLineDoesNot() {
        let (w, h) = (40, 40)
        let ring = Self.grid(w, h) { x, y in (10..<12).contains(hypotf(Float(x) - 20, Float(y) - 20)) }
        let closed = K.closeLoops(width: w, height: h, mask: ring)
        #expect(closed[20 * w + 20], "the centre is enclosed")
        #expect(!closed[2 * w + 2], "the outside stays outside")
        let line = Self.grid(w, h) { x, y in y == 20 && (5..<35).contains(x) }
        #expect(K.closeLoops(width: w, height: h, mask: line) == line, "an open stroke encloses nothing")
    }

    @Test func aLoopOpenAtOnePixelEnclosesNothing() {
        let (w, h) = (20, 20)
        var sq = Self.grid(w, h) { x, y in (x == 5 || x == 14 || y == 5 || y == 14) && (5...14).contains(x) && (5...14).contains(y) }
        sq[5 * w + 9] = false
        #expect(!K.closeLoops(width: w, height: h, mask: sq)[10 * w + 10])
    }

    @Test func dilateGrowsByTheRadius() {
        let (w, h) = (11, 11)
        let dot = Self.grid(w, h) { x, y in (x, y) == (5, 5) }
        let d = K.dilate(width: w, height: h, mask: dot, radius: 2)
        #expect(d.filter { $0 }.count == 25)
        #expect(d[3 * w + 3] && d[7 * w + 7] && !d[2 * w + 5])
        #expect(K.dilate(width: w, height: h, mask: dot, radius: 0) == dot)
    }

    @Test func radiusMeasuresTheThickestPart() {
        let (w, h) = (30, 30)
        #expect(K.holeRadius(width: w, height: h, hole: Self.grid(w, h) { x, y in y == 10 && (5..<25).contains(x) }) == 1)
        #expect(K.holeRadius(width: w, height: h, hole: Self.grid(w, h) { x, y in (5..<16).contains(x) && (5..<16).contains(y) }) == 6)
        #expect(K.holeRadius(width: w, height: h, hole: [Bool](repeating: true, count: w * h)) == .max)
        #expect(K.holeRadius(width: w, height: h, hole: [true]) == 0, "a mask of the wrong size")
    }

    /// A hole in a horizontal gradient is filled close to the gradient, both thin and wide.
    @Test func removesThinAndWideHolesFromAGradient() throws {
        let (w, h, ch) = (64, 48, 2)
        let truth: [Float] = (0..<(w * h)).flatMap { [Float($0 % w) / Float(w), 1] }
        for hole in [Self.grid(w, h) { x, y in y == 24 && (10..<54).contains(x) }, Self.grid(w, h) { x, y in (24..<40).contains(x) && (16..<32).contains(y) }] {
            var img = truth
            for (i, m) in hole.enumerated() where m { img[i * ch] = 1 }
            let out = try K.removeWith(width: w, height: h, channels: ch, image: img, hole: hole, seed: 7)
            for (i, m) in hole.enumerated() {
                if m { #expect(abs(out[i * ch] - truth[i * ch]) < 0.12, "pixel \(i): \(out[i * ch]) vs \(truth[i * ch])") }
                else { #expect(out[(i * ch)..<((i + 1) * ch)] == img[(i * ch)..<((i + 1) * ch)], "outside the hole is untouched") }
            }
        }
    }

    /// A long, thin diagonal hole goes tile by tile; every cell is filled, the rest is untouched.
    @Test func aLongThinHoleIsFilledInTiles() throws {
        let (w, h, ch) = (900, 700, 1)
        let img: [Float] = (0..<(w * h)).map { 0.3 + 0.4 * Float((($0 % w) / 7 + ($0 / w) / 5) % 2) }
        let hole = Self.grid(w, h) { x, y in abs(Float(x) - Float(y) * 1.2 - 20) < 3 && (40..<680).contains(y) }
        var holed = img
        for (i, m) in hole.enumerated() where m { holed[i] = 1 }
        let out = try K.removeWith(width: w, height: h, channels: ch, image: holed, hole: hole, seed: 3)
        var bad = 0
        for (i, m) in hole.enumerated() {
            if m { if !(0.29...0.71).contains(out[i]) { bad += 1 } } else if out[i] != holed[i] { bad += 1 }
        }
        #expect(bad == 0, "\(bad) cells wrong")
    }

    @Test func hostileSizesReturnTheInput() throws {
        let img = [Float](repeating: 0.5, count: 12)
        #expect(try K.removeWith(width: 2, height: 2, channels: 3, image: img, hole: [true], seed: 1) == img)
        #expect(try K.removeWith(width: 2, height: 2, channels: 0, image: img, hole: [Bool](repeating: true, count: 4), seed: 1) == img)
        #expect(try K.removeWith(width: 3, height: 2, channels: 2, image: img, hole: [Bool](repeating: false, count: 6), seed: 1) == img)
        #expect(K.closeLoops(width: 0, height: 0, mask: []).isEmpty)
        #expect(K.dilate(width: 3, height: 3, mask: [true], radius: 1) == [true])
    }

    // MARK: photocraft nonlocal.rs

    static func noise(_ i: Int) -> Float { Float((UInt32(truncatingIfNeeded: i) &* 2_654_435_761) >> 8) / Float(1 << 24) }

    /// Mean |∂x| + |∂y| over the masked cells (one channel).
    static func grain(_ w: Int, _ img: [Float], _ m: [Bool]) -> Float {
        var s: Float = 0
        var n = 0
        for (i, mm) in m.enumerated() where mm && i % w + 1 < w && i + w < img.count {
            s += abs(img[i + 1] - img[i]) + abs(img[i + w] - img[i])
            n += 1
        }
        return s / Float(max(n, 1))
    }

    /// photocraft `a_hole_in_texture_next_to_a_flat_area_of_the_same_mean_gets_texture`.
    @Test func aHoleInTextureNextToAFlatAreaGetsTexture() throws {
        let (w, h) = (96, 64)
        let img: [Float] = (0..<(w * h)).map { $0 % w < 48 ? 0.5 : 0.25 + 0.5 * Self.noise($0) }
        let hole = Self.grid(w, h) { x, y in (60..<84).contains(x) && (20..<44).contains(y) }
        let out = try #require(try K.nonLocalComplete(width: w, height: h, channels: 1, image: img, hole: hole))
        let (filled, truth) = (Self.grain(w, out, hole), Self.grain(w, img, hole))
        #expect(filled > truth * 0.7, "the fill is smoother than the texture around it: \(filled) vs \(truth)")
        #expect((0..<(w * h)).allSatisfy { hole[$0] || out[$0] == img[$0] }, "known cells are kept")
    }

    @Test func aHoleInAGradientFollowsTheGradient() throws {
        let (w, h, ch) = (80, 60, 2)
        let img: [Float] = (0..<(w * h)).flatMap { [Float($0 % w) / Float(w), 1] }
        let hole = Self.grid(w, h) { x, y in (30..<50).contains(x) && (20..<40).contains(y) }
        let out = try #require(try K.nonLocalComplete(width: w, height: h, channels: ch, image: img, hole: hole))
        for (i, m) in hole.enumerated() where m { #expect(abs(out[i * ch] - img[i * ch]) < 0.1, "cell \(i): \(out[i * ch]) vs \(img[i * ch])") }
    }

    @Test func levelsFollowTheHoleThickness() {
        let (w, h) = (400, 400)
        let line = Self.grid(w, h) { x, y in y == 200 && (20..<380).contains(x) }
        #expect(K.NL.levelCount(w, h, line, 3) == 1, "a thin line stays at full resolution")
        let disc = Self.grid(w, h) { x, y in hypotf(Float(x) - 200, Float(y) - 200) < 90 }
        #expect(K.NL.levelCount(w, h, disc, 3) == 5, "⌈log2(2·90/7)⌉")
    }

    @Test func nothingToCopyFromAndBadSizes() throws {
        let img = [Float](repeating: 0.5, count: 144)
        #expect(try K.nonLocalComplete(width: 12, height: 12, channels: 1, image: img, hole: [Bool](repeating: true, count: 144)) == nil)
        #expect(try K.nonLocalComplete(width: 12, height: 12, channels: 1, image: img, hole: [true, true, true]) == img)
        #expect(try K.nonLocalComplete(width: 12, height: 12, channels: 0, image: img, hole: [Bool](repeating: true, count: 144)) == img)
    }

    @Test func cancelledIsAnError() {
        let (w, h) = (64, 64)
        let img = (0..<(w * h)).map(Self.noise)
        let hole = Self.grid(w, h) { x, y in (20..<40).contains(x) && (20..<40).contains(y) }
        #expect(throws: K.Cancelled.self) { _ = try K.nonLocalComplete(width: w, height: h, channels: 1, image: img, hole: hole, interrupt: .cancelOnly { true }) }
    }
}
