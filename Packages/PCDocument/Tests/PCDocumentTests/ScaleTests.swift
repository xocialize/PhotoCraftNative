// Large documents: auto slices and slice resolution at 10 000 slices (the band sweep against
// photocraft's grid scan) and the shared-tile Background of `Document.withBackground` (#705).
// MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import PCFoundation
import Testing
@testable import PCDocument

/// photocraft's `auto_slices` as it was ported first: every grid cell tested against every slice.
func gridScanAutoSlices(canvas: PixelRect, taken: [PixelRect]) -> [PixelRect] {
    if canvas.isEmpty { return [] }
    var xs: [Int32] = [canvas.x0, canvas.x1]
    var ys: [Int32] = [canvas.y0, canvas.y1]
    for r0 in taken {
        let r = r0.intersect(canvas)
        if r.isEmpty { continue }
        xs += [r.x0, r.x1]
        ys += [r.y0, r.y1]
    }
    xs = Array(Set(xs)).sorted()
    ys = Array(Set(ys)).sorted()
    func covered(_ x0: Int32, _ y0: Int32) -> Bool {
        taken.contains { x0 >= $0.x0 && x0 < $0.x1 && y0 >= $0.y0 && y0 < $0.y1 }
    }
    var runs: [PixelRect] = []
    for yi in 0..<(ys.count - 1) {
        let (ya, yb) = (ys[yi], ys[yi + 1])
        var start: Int32?
        for xi in 0..<(xs.count - 1) {
            let free = !covered(xs[xi], ya)
            if free, start == nil {
                start = xs[xi]
            } else if !free, let s = start {
                runs.append(PixelRect(x0: s, y0: ya, x1: xs[xi], y1: yb))
                start = nil
            }
        }
        if let s = start { runs.append(PixelRect(x0: s, y0: ya, x1: xs.last ?? canvas.x1, y1: yb)) }
    }
    var out: [PixelRect] = []
    for r in runs {
        if let i = out.firstIndex(where: { $0.x0 == r.x0 && $0.x1 == r.x1 && $0.y1 == r.y0 }) {
            out[i].y1 = r.y1
        } else {
            out.append(r)
        }
    }
    return out
}

/// SplitMix64.
struct SliceRNG {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func int(_ r: ClosedRange<Int>) -> Int32 { Int32(r.lowerBound + Int(next() % UInt64(r.count))) }
}

@Suite struct SliceScaleTests {
    /// The sweep gives exactly the grid scan's rectangles, in its order, for random slices that
    /// overlap, touch, repeat, leave the canvas, are empty or inverted, on canvases off the origin.
    @Test func autoSlicesMatchTheGridScan() {
        var rng = SliceRNG(state: 2024)
        for round in 0..<400 {
            let cx = rng.int(-50...50), cy = rng.int(-50...50)
            let canvas = PixelRect(x0: cx, y0: cy, x1: cx + rng.int(1...120), y1: cy + rng.int(1...90))
            let n = Int(rng.int(0...(round % 4 == 0 ? 60 : 12)))
            var taken: [PixelRect] = []
            for _ in 0..<n {
                let x0 = rng.int(-80...180), y0 = rng.int(-80...150)
                // Small sizes so edges coincide often; some inverted or empty.
                taken.append(PixelRect(x0: x0, y0: y0, x1: x0 + rng.int(-3...60), y1: y0 + rng.int(-3...50)))
            }
            if round % 7 == 0, let first = taken.first { taken.append(first) }
            #expect(autoSlices(canvas: canvas, taken: taken) == gridScanAutoSlices(canvas: canvas, taken: taken), "round \(round): \(canvas) \(taken)")
        }
        // Edge cases.
        let c = PixelRect(x0: 0, y0: 0, x1: 100, y1: 80)
        for taken in [[], [c], [c.outset(by: 5)], [PixelRect(x0: 200, y0: 0, x1: 300, y1: 10)], [PixelRect(x0: 0, y0: 0, x1: 100, y1: 1)],
                      [PixelRect(x0: 20, y0: 10, x1: 60, y1: 30), PixelRect(x0: 30, y0: 20, x1: 80, y1: 50)]] {
            #expect(autoSlices(canvas: c, taken: taken) == gridScanAutoSlices(canvas: c, taken: taken), "\(taken)")
        }
        #expect(autoSlices(canvas: .empty, taken: [c]).isEmpty)
    }

    func timed<T>(_ body: () -> T) -> (T, Duration) {
        let clock = ContinuousClock()
        let start = clock.now
        let v = body()
        return (v, clock.now - start)
    }

    /// 10 000 slices (Divide Slice's limit, #1020) resolve in well under a second in Debug: the
    /// grid scan and the per-slice lookups took ≈ 17 s.
    @Test func tenThousandSlicesResolveFast() {
        // A 100 × 100 division of the whole canvas: no auto slices.
        var grid = Document(name: "grid.psd", size: PixelSize(width: 1000, height: 1000), mode: .rgb, depth: .u8)
        for j in 0..<100 {
            for i in 0..<100 {
                grid.slices.list.append(Slice(id: UInt32(j * 100 + i + 1),
                                              rect: PixelRect(x0: Int32(i * 10), y0: Int32(j * 10), x1: Int32(i * 10 + 10), y1: Int32(j * 10 + 10))))
            }
        }
        let (g, gt) = timed { grid.resolvedSlices() }
        #expect(g.count == 10_000 && g.allSatisfy { $0.origin == .user })
        #expect(g[0].number == 1 && g[0].id == 1 && g[0].name == "grid_01" && g[9_999].id == 10_000 && g[9_999].name == "grid_10000")
        #expect(gt < .seconds(1), "100 × 100 grid: \(gt)")
        // 10 000 slices with gaps between them: about as many auto slices fill the gaps.
        var gaps = Document(name: "gaps", size: PixelSize(width: 1000, height: 1000), mode: .rgb, depth: .u8)
        for j in 0..<100 {
            for i in 0..<100 {
                gaps.slices.list.append(Slice(id: UInt32(j * 100 + i + 1),
                                              rect: PixelRect(x0: Int32(i * 10 + 1), y0: Int32(j * 10 + 1), x1: Int32(i * 10 + 9), y1: Int32(j * 10 + 9))))
            }
        }
        let (r, rt) = timed { gaps.resolvedSlices() }
        #expect(rt < .seconds(1), "with gaps: \(rt)")
        // 101 full-width gap bands, and 101 gaps across each of the 100 slice rows.
        #expect(r.count == 10_000 + 101 + 100 * 101, "\(r.count)")
        #expect(r.map(\.number) == Array(1...r.count))
        let area = r.reduce(0) { $0 + $1.rect.area }
        #expect(area == 1000 * 1000)
        // 10 000 random, overlapping slices.
        var rng = SliceRNG(state: 99)
        var messy = Document(name: "messy", size: PixelSize(width: 4000, height: 3000), mode: .rgb, depth: .u8)
        for k in 0..<10_000 {
            let x = rng.int(-100...4000), y = rng.int(-100...3000)
            messy.slices.list.append(Slice(id: UInt32(k + 1), rect: PixelRect(x0: x, y0: y, x1: x + rng.int(1...60), y1: y + rng.int(1...40))))
        }
        let (m, mt) = timed { messy.resolvedSlices() }
        #expect(mt < .seconds(1), "random: \(mt) for \(m.count) slices")
        #expect(m.filter { $0.origin == .auto }.allSatisfy { $0.id == nil })
    }

    @Test func resolvedSlicesLookUpTheFirstSliceWithEachId() {
        var d = Document(name: "dup", size: PixelSize(width: 100, height: 100), mode: .rgb, depth: .u8)
        d.slices.list = [Slice(id: 1, rect: PixelRect(x0: 0, y0: 0, x1: 10, y1: 10), name: "first"),
                         Slice(id: 1, rect: PixelRect(x0: 50, y0: 50, x1: 60, y1: 60), name: "second")]
        let r = d.resolvedSlices().filter { $0.id == 1 }
        #expect(r.map(\.name) == ["first", "first"], "both entries use the first slice's options, as `get` does")
    }
}

@Suite struct BackgroundScaleTests {
    /// Distinct pixel buffers behind a surface's tiles.
    func buffers(_ s: Surface) -> Int {
        var seen = Set<UInt>()
        s.forEachTile { _, t in t.bytes.withUnsafeBytes { _ = seen.insert(UInt(bitPattern: $0.baseAddress)) } }
        return seen.count
    }

    /// File › New at photocraft's size limit used to fill ~360 GB of tiles (#705): the Background
    /// shares one solid tile, plus one per edge shape.
    @Test func aHugeBackgroundCostsAFewTiles() throws {
        for (fill, mode, depth) in [(PCColor.white, ColorMode.rgb, SampleType.u8), (.rgb(0.2, 0.4, 0.6), .cmyk, .f32), (.black, .grayscale, .u16)] {
            let d = Document.withBackground(name: "big", size: PixelSize(width: 100_003, height: 70_001), mode: mode, depth: depth, fill: fill)
            let s = try #require(d.layers.first?.surface)
            #expect(s.tileCount == 391 * 274)
            #expect(buffers(s) <= 4, "\(mode) \(depth): \(buffers(s))")
            #expect(s.pixel(x: 100_002, y: 70_000) == s.pixel(x: 0, y: 0))
            #expect(s.pixel(x: 100_003, y: 5).last == 0, "outside the canvas")
            #expect(s.contentBounds == d.bounds)
        }
    }
}

@Suite struct RunLengthTests {
    /// photocraft writes run lengths as `usize`: a `.pcraft` can hold up to `u64::MAX`, which
    /// decodes saturated to `Int.max` instead of failing the whole document.
    @Test func runLengthsDecodeSaturating() throws {
        let text = try encodeJSON(TextRun(len: 7, style: CharStyle()))
        let para = try encodeJSON(ParagraphRun(len: 7, style: ParagraphStyle()))
        for (raw, want) in [("18446744073709551615", Int.max), ("9223372036854775808", Int.max), ("9223372036854775807", Int.max), ("12", 12), ("-3", -3)] {
            let t = try decodeJSON(TextRun.self, text.replacingOccurrences(of: "\"len\":7", with: "\"len\":\(raw)"))
            let p = try decodeJSON(ParagraphRun.self, para.replacingOccurrences(of: "\"len\":7", with: "\"len\":\(raw)"))
            #expect(t.len == want && p.len == want, "\(raw)")
        }
        #expect(throws: (any Error).self) { try decodeJSON(TextRun.self, text.replacingOccurrences(of: "\"len\":7", with: "\"len\":\"x\"")) }
        #expect(try roundTrip(TextRun(len: Int.max, style: CharStyle())).len == Int.max)
    }

    @Test func remEuclidIsRustsRemEuclid() {
        #expect(remEuclid(-30, 360) == 330 && remEuclid(725, 360) == 5 && remEuclid(-0.5, -2) == 1.5 && remEuclid(0, 360) == 0)
    }
}
