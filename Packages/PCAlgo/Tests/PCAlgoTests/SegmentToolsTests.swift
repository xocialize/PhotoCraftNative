// Port of photocraft-algo (crates/algo/src/magnetic/tests.rs, erase.rs and paint.rs bucket tests), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import Testing
@testable import PCAlgo
import PCFoundation

enum MagTest {
    final class Counter { var read = 0 }

    /// A procedural image as a fetch that counts the pixels it reads.
    static func image(_ c: Counter, _ f: @escaping (Int32, Int32) -> SIMD4<UInt8>) -> MagneticLasso.Fetch {
        { r in
            c.read += r.area
            var out: [SIMD4<UInt8>] = []
            out.reserveCapacity(r.area)
            for y in r.y0..<r.y1 { for x in r.x0..<r.x1 { out.append(f(x, y)) } }
            return out
        }
    }

    static func grey(_ v: UInt8) -> SIMD4<UInt8> { SIMD4(v, v, v, 255) }

    /// Distance from `p` to the polyline `g`.
    static func offPolyline(_ p: SIMD2<Double>, _ g: [SIMD2<Double>]) -> Double {
        var best = Double.infinity
        if g.count >= 2 { for i in 1..<g.count { best = min(best, MagneticLasso.dist2Segment(p, g[i - 1], g[i]).squareRoot()) } }
        return best
    }

    static func rect(_ w: Int32, _ h: Int32) -> PixelRect { PixelRect(x0: 0, y0: 0, x1: w, y1: h) }

    /// `#require` for results of mutating calls (the macro can't take them inline).
    static func some<T>(_ v: T?, sourceLocation: SourceLocation = #_sourceLocation) throws -> T { try #require(v, sourceLocation: sourceLocation) }
}

struct SegmentMagneticTests {
    typealias S = MagneticLasso.Settings

    @Test func snapsToTheEdgeCentreWithinTheWidth() throws {
        let c = MagTest.Counter()
        // Black left of x = 20, white from it.
        let f = MagTest.image(c) { x, _ in MagTest.grey(x < 20 ? 0 : 255) }
        var t = MagneticLasso.Tracer(bounds: MagTest.rect(64, 32))
        let p = try MagTest.some(t.snap(f, SIMD2(14.3, 10.5), S(width: 10, contrast: 0.1)))
        #expect(abs(p.x - 20) < 0.01 && abs(p.y - 10.5) < 0.01, "on the step, not half a pixel off: \(p)")
        // From the other side too.
        let q = try MagTest.some(t.snap(f, SIMD2(27, 3.2), S(width: 10, contrast: 0.1)))
        #expect(abs(q.x - 20) < 0.01, "\(q)")
        // Out of reach: the point stays where it is.
        #expect(t.snap(f, SIMD2(14.3, 10.5), S(width: 3, contrast: 0.1)) == SIMD2(14.3, 10.5))
    }

    @Test func contrastSetsWhichStepsAreEdges() throws {
        let c = MagTest.Counter()
        // A 5% step.
        let f = MagTest.image(c) { x, _ in MagTest.grey(x < 20 ? 100 : 113) }
        var t = MagneticLasso.Tracer(bounds: MagTest.rect(64, 32))
        #expect(t.snap(f, SIMD2(14.3, 10.5), S(width: 10, contrast: 0.10)) == SIMD2(14.3, 10.5), "too faint at 10%")
        let p = try MagTest.some(t.snap(f, SIMD2(14.3, 10.5), S(width: 10, contrast: 0.03)))
        #expect(abs(p.x - 20) < 0.01, "an edge at 3%: \(p)")
    }

    @Test func snapsToTheMostProminentEdge() throws {
        let c = MagTest.Counter()
        // A faint step at x = 12 and a strong one at x = 18.
        let f = MagTest.image(c) { x, _ in MagTest.grey([0, 40, 255][(x >= 12 ? 1 : 0) + (x >= 18 ? 1 : 0)]) }
        var t = MagneticLasso.Tracer(bounds: MagTest.rect(40, 20))
        let p = try MagTest.some(t.snap(f, SIMD2(13, 10), S(width: 10, contrast: 0.1)))
        #expect(abs(p.x - 18) < 0.01, "\(p)")
    }

    @Test func traceFollowsACurvedEdge() throws {
        let c = MagTest.Counter()
        // A white disc of radius 30 at (50, 50) on black.
        let f = MagTest.image(c) { x, y in MagTest.grey(hypot(Double(x) + 0.5 - 50, Double(y) + 0.5 - 50) < 30 ? 255 : 0) }
        var t = MagneticLasso.Tracer(bounds: MagTest.rect(100, 100))
        let s = S.default
        let a = try MagTest.some(t.snap(f, SIMD2(50, 21), s))
        let b = try MagTest.some(t.snap(f, SIMD2(79, 50), s))
        // The pointer went straight from one to the other; the border bows out along the disc.
        let path = t.trace(f, from: a, to: b, guide: [], s)
        #expect(path.count > 4, "\(path)")
        #expect(path.first == a && path.last == b)
        for p in path {
            let r = hypot(p.x - 50, p.y - 50)
            #expect(abs(r - 30) < 1, "\(p) is \(r) from the centre")
        }
    }

    @Test func withoutEdgesTheBorderFollowsThePointer() {
        let c = MagTest.Counter()
        let f = MagTest.image(c) { _, _ in MagTest.grey(128) }
        var t = MagneticLasso.Tracer(bounds: MagTest.rect(120, 80))
        let s = S.default
        // A gentle curve: the border runs along it.
        let a = SIMD2<Double>(10, 40), b = SIMD2<Double>(110, 40)
        let guide = (1..<10).map { i in SIMD2(10 + Double(i) * 10, 40 - 15 * sin(Double(i) * Double.pi / 10)) }
        let g = [a] + guide + [b]
        let path = t.trace(f, from: a, to: b, guide: guide, s)
        for p in path { #expect(MagTest.offPolyline(p, g) < 2, "\(p) strays from the pointer: \(path)") }
        #expect(MagTest.offPolyline(SIMD2(60, 25), path) < 2, "the border went where the pointer went: \(path)")
        // A sharp turn: the border may round it off, but never leaves the detection width.
        let path2 = t.trace(f, from: SIMD2(10, 10), to: SIMD2(100, 75), guide: [SIMD2(30, 70)], s)
        for p in path2 { #expect(MagTest.offPolyline(p, [SIMD2(10, 10), SIMD2(30, 70), SIMD2(100, 75)]) <= s.width, "\(p): \(path2)") }
        // A straight pointer path over nothing is one straight segment.
        #expect(t.trace(f, from: SIMD2(10, 10), to: SIMD2(110, 73), guide: [], s) == [SIMD2(10, 10), SIMD2(110, 73)])
    }

    @Test func theCorridorKeepsTheBorderOffEdgesThePointerNeverWentNear() {
        let c = MagTest.Counter()
        // A modest step at y = 20, under the pointer, and a much stronger one at y = 40.
        let f = MagTest.image(c) { _, y in MagTest.grey([60, 100, 255][(y >= 20 ? 1 : 0) + (y >= 40 ? 1 : 0)]) }
        var t = MagneticLasso.Tracer(bounds: MagTest.rect(120, 60))
        let path = t.trace(f, from: SIMD2(10, 22), to: SIMD2(110, 18), guide: [SIMD2(60, 23)], S(width: 10, contrast: 0.1))
        for p in path { #expect(abs(p.y - 20) <= 2 + 1e-9, "\(p) left the edge under the pointer: \(path)") }
        // Away from the ends it runs on the step itself.
        #expect(path.filter { $0.x > 25 && $0.x < 95 }.allSatisfy { abs($0.y - 20) < 0.01 }, "\(path)")
    }

    @Test func longGuidesAreTracedInPiecesAlongTheEdge() {
        let c = MagTest.Counter()
        // A step at y = 30 across a wide image; the pointer wavers 4 px either side of it.
        let f = MagTest.image(c) { _, y in MagTest.grey(y < 30 ? 20 : 200) }
        var t = MagneticLasso.Tracer(bounds: MagTest.rect(1000, 60))
        let guide = (1..<20).map { i in SIMD2(Double(i) * 50, i % 2 == 0 ? 26 : 34) }
        let path = t.trace(f, from: SIMD2(5, 30), to: SIMD2(995, 30), guide: guide, .default)
        for p in path { #expect(abs(p.y - 30) < 0.01, "\(p)") }
        let len = MagneticLasso.length(path)
        #expect(abs(len - 990) < 1, "a straight border, not a zigzag: \(len)")
        // Collinear points are dropped.
        #expect(path.count < 20, "\(path.count)")
    }

    @Test func readsOnlyThePixelsAroundTheBorder() throws {
        let c = MagTest.Counter()
        let f = MagTest.image(c) { x, _ in MagTest.grey(x < 3000 ? 0 : 255) }
        // A 24 MP image.
        var t = MagneticLasso.Tracer(bounds: MagTest.rect(6000, 4000))
        let s = S.default
        let a = try MagTest.some(t.snap(f, SIMD2(2996, 2000), s))
        let b = try MagTest.some(t.snap(f, SIMD2(3004, 2100), s))
        let path = t.trace(f, from: a, to: b, guide: [], s)
        #expect(path.allSatisfy { abs($0.x - 3000) < 0.01 }, "\(path)")
        let first = c.read
        #expect(first <= 6 * 128 * 128, "read \(first) px")
        #expect(t.cachedPixels == first)
        // The same area again comes from the cache.
        _ = t.trace(f, from: a, to: b, guide: [], s)
        #expect(c.read == first)
    }

    @Test func hostileInputNeverPanics() throws {
        let c = MagTest.Counter()
        let f = MagTest.image(c) { x, y in MagTest.grey(UInt8((x ^ y) & 255)) }
        let s = S.default
        // No image at all.
        var empty = MagneticLasso.Tracer(bounds: .empty)
        #expect(empty.snap(f, SIMD2(1, 1), s) == nil)
        #expect(empty.trace(f, from: SIMD2(1, 1), to: SIMD2(5, 5), guide: [], s).isEmpty)
        var t = MagneticLasso.Tracer(bounds: MagTest.rect(50, 40))
        // Not points.
        #expect(t.snap(f, SIMD2(.nan, 1), s) == nil)
        #expect(t.trace(f, from: SIMD2(.infinity, 1), to: SIMD2(5, 5), guide: [], s).isEmpty)
        // Far outside the image: kept inside it.
        let path = t.trace(f, from: SIMD2(-1e300, -1e9), to: SIMD2(1e9, 1e300), guide: [SIMD2(.nan, 3), SIMD2(1e12, -5)], s)
        #expect(path.allSatisfy { (0...50).contains($0.x) && (0...40).contains($0.y) }, "\(path)")
        // Nonsense settings are clamped, whichever way they arrive.
        for bad in [S(raw: .nan, .nan), S(raw: 1e300, -4), S(raw: -3, 1e30)] {
            _ = try MagTest.some(t.snap(f, SIMD2(20, 20), bad))
            #expect(!t.trace(f, from: SIMD2(2, 2), to: SIMD2(45, 30), guide: [SIMD2(10, 35)], bad).isEmpty)
        }
        // A fetch that returns the wrong amount of pixels reads as transparent.
        let badFetch: MagneticLasso.Fetch = { _ in [SIMD4<UInt8>](repeating: SIMD4(repeating: 255), count: 3) }
        var t2 = MagneticLasso.Tracer(bounds: MagTest.rect(300, 300))
        #expect(t2.snap(badFetch, SIMD2(150, 150), s) == SIMD2(150, 150))
        let p2 = t2.trace(badFetch, from: SIMD2(10, 10), to: SIMD2(290, 280), guide: [], s)
        #expect(p2.first == SIMD2(10, 10) && p2.last == SIMD2(290, 280))
        // The same point twice.
        #expect(t2.trace(badFetch, from: SIMD2(7, 7), to: SIMD2(7, 7), guide: [], s) == [SIMD2(7, 7), SIMD2(7, 7)])
    }

    @Test func splitAndSimplify() {
        let g: [SIMD2<Double>] = [SIMD2(0, 0), SIMD2(600, 0), SIMD2(600, 100)]
        let pieces = MagneticLasso.split(g, 256)
        #expect(pieces.count == 3)
        #expect(pieces[0] == [SIMD2(0, 0), SIMD2(256, 0)])
        #expect(pieces[2].last == SIMD2(600, 100))
        let total = pieces.map { MagneticLasso.length($0) }.reduce(0, +)
        #expect(abs(total - 700) < 1e-9)
        #expect(MagneticLasso.simplify([SIMD2(0, 0), SIMD2(1, 0.1), SIMD2(2, 0), SIMD2(3, 5)], 0.3) == [SIMD2(0, 0), SIMD2(2, 0), SIMD2(3, 5)])
        #expect(MagneticLasso.split([], 256).isEmpty)
    }
}

struct SegmentEraseBucketTests {
    static func region(_ bbox: PixelRect, _ v: UInt8) -> SelectionRegion {
        SelectionRegion(bbox: bbox, mask: [UInt8](repeating: v, count: bbox.area))
    }

    static func r(_ x0: Int32, _ y0: Int32, _ x1: Int32, _ y1: Int32) -> PixelRect { PixelRect(x0: x0, y0: y0, x1: x1, y1: y1) }

    // MARK: erase.rs

    @Test func erasesAlphaInEveryFormat() {
        for mode in [ColorMode.rgb, .cmyk, .grayscale, .lab] {
            for sample in [SampleType.u8, .u16, .f32] {
                let fmt = PixelFormat(mode: mode, sample: sample, alpha: true)
                let colour = fmt.components(fromRGBA: SIMD4(0.2, 0.5, 0.7, 1))
                var s = Surface(format: fmt)
                s.fill(Self.r(0, 0, 600, 300), with: colour)
                let before = s.pixel(x: 10, y: 10)
                let d = MagicEraser.erase(&s, region: Self.region(Self.r(0, 0, 300, 300), 255), amount: 1)
                #expect(d == Self.r(0, 0, 300, 300))
                #expect(s.rgba(x: 10, y: 10).w == 0, "\(fmt)")
                #expect(s.pixel(x: 400, y: 10) == before, "outside the region is untouched \(fmt)")
                // Half opacity halves alpha and keeps colour.
                var h = Surface(format: fmt)
                h.fill(Self.r(0, 0, 10, 10), with: colour)
                MagicEraser.erase(&h, region: Self.region(Self.r(0, 0, 10, 10), 255), amount: 0.5)
                let p = h.pixel(x: 5, y: 5)
                let a = fmt.mode.colorChannels
                #expect(abs(p[a] - 0.5) < 0.01, "\(fmt) \(p)")
                #expect(abs(p[0] - before[0]) < 1e-6, "colour kept \(fmt)")
            }
        }
    }

    @Test func respectsSelectionAndLock() {
        var s = Surface(format: .rgba8)
        s.fill(Self.r(0, 0, 20, 20), with: [1, 0, 0, 1])
        var sel = Surface(format: .gray8)
        sel.fill(Self.r(0, 0, 10, 20), with: [1])
        MagicEraser.erase(&s, region: Self.region(Self.r(0, 0, 20, 20), 255), amount: 1, selection: sel)
        #expect(s.rgba(x: 5, y: 5).w == 0)
        #expect(s.rgba(x: 15, y: 5).w == 1)
        // Locked transparency paints the lock colour, alpha kept.
        var l = Surface(format: .rgba8)
        l.fill(Self.r(0, 0, 20, 20), with: [1, 0, 0, 1])
        MagicEraser.erase(&l, region: Self.region(Self.r(0, 0, 20, 20), 255), amount: 1, lockColor: [1, 1, 1])
        #expect(l.rgba(x: 5, y: 5) == SIMD4(1, 1, 1, 1))
    }

    @Test func degenerateInputsDoNothing() {
        var s = Surface(format: .rgba8)
        s.fill(Self.r(0, 0, 4, 4), with: [1, 0, 0, 1])
        let orig = s
        // Mask length mismatch, zero/NaN amount, empty box.
        #expect(MagicEraser.erase(&s, region: SelectionRegion(bbox: Self.r(0, 0, 4, 4), mask: [255, 255, 255]), amount: 1).isEmpty)
        #expect(MagicEraser.erase(&s, region: Self.region(Self.r(0, 0, 4, 4), 255), amount: .nan).isEmpty)
        #expect(MagicEraser.erase(&s, region: Self.region(.empty, 255), amount: 1).isEmpty)
        #expect(s == orig)
        // No alpha channel and no lock colour: nothing to erase.
        var g = Surface(format: .gray8)
        #expect(MagicEraser.erase(&g, region: Self.region(Self.r(0, 0, 4, 4), 255), amount: 1).isEmpty)
    }

    // MARK: paint.rs (bucket)

    @Test func bucketFillsContiguousRegion() {
        var s = Surface(format: .rgba8)
        let a = Self.r(0, 0, 10, 10)
        s.fill(a, with: [1, 1, 1, 1])
        s.fill(Self.r(5, 0, 6, 10), with: [0, 0, 0, 1])
        #expect(PaintBucket.fill(&s, area: a, seed: (1, 1), tolerance: 10, contiguous: true, antiAlias: false, color: SIMD4(1, 0, 0, 1), opacity: 1))
        #expect(s.pixel(x: 2, y: 2) == [1, 0, 0, 1])
        #expect(s.pixel(x: 8, y: 2) == [1, 1, 1, 1])
        #expect(!PaintBucket.fill(&s, area: a, seed: (50, 1), tolerance: 10, contiguous: true, antiAlias: false, color: SIMD4(1, 0, 0, 1), opacity: 1))
    }

    @Test func bucketRegionUsesDocumentCoordinatesAndMultipliesCoverage() {
        var s = Surface(format: .rgba8)
        let region = SelectionRegion(bbox: Self.r(-3, 4, 0, 5), mask: [255, 128, 255])
        var selection = Surface(format: .gray8)
        selection.fill(Self.r(-3, 4, -1, 5), with: [0.5])
        PaintBucket.fill(&s, region: region, opacity: 0.5, selection: selection) { _, _ in SIMD4(1, 0, 0, 1) }
        #expect(abs(s.rgba(x: -3, y: 4).w - 0.25) < 0.005)
        #expect(abs(s.rgba(x: -2, y: 4).w - 0.125) < 0.005)
        #expect(s.rgba(x: -1, y: 4) == .zero, "outside the selection")
        #expect(s.rgba(x: -4, y: 4) == .zero, "outside the region")
    }

    /// The bucket over a CMYK, 16-bit and Lab surface lands the colour in the surface's model
    /// (the composite runs in straight sRGB like the Gradient tool).
    @Test func bucketWorksInEveryModel() {
        for fmt in [PixelFormat(mode: .cmyk, sample: .u16, alpha: true), PixelFormat(mode: .lab, sample: .f32, alpha: true), .graya8] {
            var s = Surface(format: fmt)
            let a = Self.r(0, 0, 8, 8)
            s.fill(a, with: fmt.components(fromRGBA: SIMD4(0.9, 0.9, 0.9, 1)))
            #expect(PaintBucket.fill(&s, area: a, seed: (2, 2), tolerance: 32, contiguous: true, antiAlias: false, color: SIMD4(0.1, 0.1, 0.1, 1), opacity: 1))
            let p = s.rgba(x: 4, y: 4)
            #expect(abs(p.x - 0.1) < 0.03 && p.w == 1, "\(fmt) \(p)")
        }
    }
}
