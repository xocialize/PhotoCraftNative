// Surface edge cases and fast paths: tiles at the end of the Int32 range (photocraft #963), depth
// and alpha conversion (photocraft-raster `convert`), the shared solid-tile fill, the scoped CMYK
// converter (photocraft `with_cmyk_space`), and the raw-pointer hot loops checked against the
// per-sample code they replaced. MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import Testing
@testable import PCFoundation

/// SplitMix64, for reproducible random surfaces.
struct TestRNG {
    var state: UInt64
    init(_ seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func int(_ r: Range<Int>) -> Int { r.lowerBound + Int(next() % UInt64(r.count)) }
    mutating func float() -> Float { Float(next() >> 40) / Float(1 << 24) }
}

let allTestFormats: [PixelFormat] = [
    .rgba8, .rgba16, .rgba32f, .gray8, .graya8, .gray16, .gray32f, .cmyka8,
    PixelFormat(mode: .rgb, sample: .u8, alpha: false), PixelFormat(mode: .cmyk, sample: .f32, alpha: true),
    PixelFormat(mode: .lab, sample: .u16, alpha: true),
]

// MARK: - photocraft #963

@Suite struct TileOverflowTests {
    /// photocraft #963 (`content_aware_huge_extent_is_an_error`, "extreme coordinates" and "canvas
    /// beyond i32"): a loaded document can declare a sparse selection at the most negative
    /// coordinate, at the origin and two pixels before `Int32.max`. Building, reading and bounding
    /// that selection never traps and allocates a few tiles.
    @Test func selectionAtTheEndsOfTheCoordinateRange() {
        let mx = Int32.max, mn = Int32.min
        let cases: [(String, [PixelRect])] = [
            ("extreme coordinates", [PixelRect(x0: mn, y0: mn, x1: mn + 1, y1: mn + 1), PixelRect(x0: 0, y0: 0, x1: 1, y1: 1),
                                     PixelRect(x0: mx - 2, y0: mx - 2, x1: mx - 1, y1: mx - 1)]),
            ("canvas beyond i32", [PixelRect(x0: 0, y0: 0, x1: 1, y1: 1), PixelRect(x0: mx - 2, y0: 0, x1: mx - 1, y1: 1)]),
        ]
        for (name, rects) in cases {
            var sel = Surface(format: .gray8)
            for r in rects { sel.fill(r, with: [1]) }
            #expect(sel.tileCount == rects.count, "\(name)")
            let all = rects.dropFirst().reduce(rects[0]) { $0.union($1) }
            #expect(sel.contentBounds == all, "\(name)")
            for r in rects {
                #expect(sel.pixel(x: r.x0, y: r.y0) == [1], "\(name) \(r)")
                #expect(sel.readRegion(r.outset(by: 1)).reduce(0, +) == 1, "\(name) \(r)")
            }
            // The last tile ends at Int32.max instead of overflowing.
            let last = TileCoord(containing: mx - 2, mx - 2)
            #expect(last.rect == PixelRect(x0: 2_147_483_392, y0: 2_147_483_392, x1: mx, y1: mx))
            #expect(sel.tileBounds.x1 == (name == "canvas beyond i32" ? mx : mx))
            var pruned = sel
            pruned.prune()
            #expect(pruned == sel, "\(name)")
            // Moving the far pixel back into range keeps it.
            let moved = sel.translated(dx: -10, dy: 0, content: rects.last!)
            #expect(moved.contentBounds == rects.last!.offsetBy(dx: -10, dy: 0), "\(name)")
        }
    }

    @Test func tileRectsSaturateLikeRect() {
        #expect(TileCoord(tx: 8_388_607, ty: 0).rect == PixelRect(x0: 2_147_483_392, y0: 0, x1: Int32.max, y1: 256))
        #expect(TileCoord(tx: -8_388_608, ty: -1).rect == PixelRect(x0: Int32.min, y0: -256, x1: Int32.min + 256, y1: 0))
        #expect(TileCoord(tx: Int32.max, ty: Int32.min).rect == PixelRect(x0: Int32.max, y0: Int32.min, x1: Int32.max, y1: Int32.min))
        #expect(TileCoord(tx: 3, ty: -2).rect == PixelRect(x0: 768, y0: -512, x1: 1024, y1: -256))
        // A pixel in the last column (x = Int32.max) still bounds without overflow.
        var s = Surface(format: .gray8)
        s.setPixel(x: Int32.max, y: 5, [1])
        #expect(s.pixel(x: Int32.max, y: 5) == [1])
        #expect(s.contentBounds == PixelRect(x0: Int32.max, y0: 5, x1: Int32.max, y1: 6))
    }
}

// MARK: - Depth and alpha conversion

@Suite struct ConvertTests {
    /// photocraft-raster `convert_depths_and_models`, the parts within one colour model.
    @Test func depthsAndAlpha() {
        var s = Surface(format: .rgba8)
        s.setPixel(x: 1, y: 1, [1, 1, 1, 1])
        let f = s.converted(to: .rgba32f)
        #expect(f.pixel(x: 1, y: 1) == [1, 1, 1, 1])
        #expect(f.converted(to: .rgba8) == s)
    }

    @Test func addingAlphaIsOpaqueAndRemovingItDropsIt() {
        for depth in SampleType.allCases {
            for mode in [ColorMode.rgb, .grayscale, .cmyk, .lab] {
                let opaque = PixelFormat(mode: mode, sample: depth, alpha: false)
                let withAlpha = opaque.with(alpha: true)
                let n = mode.colorChannels
                // Opaque → alpha: colour as is, alpha 1; the default pixel too.
                var a = Surface(format: opaque, defaultPixel: [Float](repeating: 0.4, count: n))
                let colour = (0..<n).map { Float($0 + 1) / Float(n + 2) }
                a.fill(PixelRect(x0: -3, y0: 250, x1: 300, y1: 262), with: colour)
                let b = a.converted(to: withAlpha.with(sample: .f32))
                #expect(b.format == withAlpha.with(sample: .f32))
                let tol: Float = depth == .f32 ? 0 : 1e-6
                let p = b.pixel(x: 10, y: 255)
                #expect(zip(p.prefix(n), a.pixel(x: 10, y: 255)).allSatisfy { abs($0 - $1) <= tol } && p[n] == 1, "\(opaque) \(p)")
                #expect(b.defaultPixelValue.last == 1 && b.pixel(x: 10, y: 9999)[n] == 1, "\(opaque)")
                #expect(b.contentBounds == a.contentBounds, "\(opaque)")
                // Alpha → opaque: alpha dropped, colour kept (no compositing), at the same depth.
                var c = Surface(format: withAlpha)
                c.fill(PixelRect(x0: 0, y0: 0, x1: 20, y1: 20), with: colour + [0.25])
                let d = c.converted(to: opaque)
                #expect(d.format == opaque && d.channels == n)
                #expect(d.pixel(x: 5, y: 5) == c.pixel(x: 5, y: 5).prefix(n).map { $0 }, "\(withAlpha)")
                #expect(d.defaultPixelValue == [Float](repeating: 0, count: n))
                // Round trip: the alpha comes back opaque.
                #expect(d.converted(to: withAlpha).pixel(x: 5, y: 5) == Array(c.pixel(x: 5, y: 5).prefix(n)) + [1])
            }
        }
    }

    @Test func sharedTilesConvertOnceAndStayShared() {
        var s = Surface(format: .rgba8)
        s.fill(PixelRect(x0: 0, y0: 0, x1: 1024, y1: 1024), with: [0.2, 0.4, 0.6, 1])
        let o = s.converted(to: PixelFormat(mode: .rgb, sample: .u16, alpha: false))
        #expect(o.tileCount == 16)
        #expect(Set(o.tileCoords.compactMap { o.tile($0)?.generation }).count == 1)
        #expect(abs(o.pixel(x: 1000, y: 3)[1] - 0.4) < 0.5 / 255)
    }
}

// MARK: - Shared solid-tile fill

/// Distinct byte buffers behind a surface's tiles (how much tile storage it really holds).
func distinctBuffers(_ s: Surface) -> Int {
    var seen = Set<UInt>()
    s.forEachTile { _, t in t.bytes.withUnsafeBytes { _ = seen.insert(UInt(bitPattern: $0.baseAddress)) } }
    return seen.count
}

@Suite struct SharedFillTests {
    @Test func aHugeFillAllocatesOneTile() {
        // 64 Ki tiles (a 65 536² canvas, 16 GiB of RGBA8 if every tile were its own).
        var s = Surface(format: .rgba8)
        let r = PixelRect(x0: 0, y0: 0, x1: 65_536, y1: 65_536)
        s.fill(r, with: [1, 1, 1, 1])
        #expect(s.tileCount == 65_536)
        #expect(distinctBuffers(s) == 1)
        #expect(Set(s.tileCoords.compactMap { s.tile($0)?.generation }).count == 1)
        #expect(s.contentBounds == r)
        #expect(s.pixel(x: 65_535, y: 65_535) == [1, 1, 1, 1])
        // A later edit copies only the tile it touches; the copy it came from keeps its storage.
        let before = s
        s.setPixel(x: 300, y: 70_000 - 69_000, [0, 0, 0, 1])
        #expect(distinctBuffers(s) == 2)
        #expect(distinctBuffers(before) == 1)
        let touched = TileCoord(containing: 300, 1000)
        #expect(s.tile(touched)?.generation != before.tile(touched)?.generation)
        #expect(s.tile(TileCoord(tx: 0, ty: 0))?.generation == before.tile(TileCoord(tx: 0, ty: 0))?.generation)
        #expect(before.pixel(x: 300, y: 1000) == [1, 1, 1, 1] && s.pixel(x: 300, y: 1000) == [0, 0, 0, 1])
    }

    @Test func partialEdgeTilesKeepTheirOtherPixels() {
        for fmt in allTestFormats {
            var s = Surface(format: fmt, defaultPixel: [Float](repeating: 0.25, count: fmt.channels))
            let mark = [Float](repeating: 0.75, count: fmt.channels)
            s.setPixel(x: 5, y: 5, mark)          // tile (0, 0): the fill covers it in part
            s.setPixel(x: 700, y: 300, mark)      // tile (2, 1): covered whole
            let r = PixelRect(x0: 10, y0: 10, x1: 1_000, y1: 600)
            let px = [Float](repeating: 0.5, count: fmt.channels)
            s.fill(r, with: px)
            #expect(s.pixel(x: 5, y: 5) == s.pixel(x: 5, y: 5) && abs(s.pixel(x: 5, y: 5)[0] - 0.75) < 1e-2, "\(fmt)")
            #expect(abs(s.pixel(x: 700, y: 300)[0] - 0.5) < 1e-2, "\(fmt)")
            #expect(abs(s.pixel(x: 9, y: 300)[0] - 0.25) < 1e-2 && abs(s.pixel(x: 10, y: 10)[0] - 0.5) < 1e-2, "\(fmt)")
            // Whole tiles (1…2, 1) share one tile. Edge tiles are written: (0, 0) keeps its mark;
            // the missing ones with the same filled part share one tile per shape (left column,
            // right column, top row, bottom row, four corners; (0, 0) is its own).
            #expect(s.tileCount == 4 * 3, "\(fmt)")
            #expect(distinctBuffers(s) == 1 + 1 + 7, "\(fmt)")
            // The same pixels as filling one by one.
            var slow = Surface(format: fmt, defaultPixel: [Float](repeating: 0.25, count: fmt.channels))
            slow.setPixel(x: 5, y: 5, mark)
            slow.setPixel(x: 700, y: 300, mark)
            slow.writeRegion(r, (0..<r.area).flatMap { _ in px })
            #expect(s == slow, "\(fmt)")
        }
    }

    @Test func pruneAndBoundsScanASharedTileOnce() {
        var s = Surface(format: .gray8, defaultPixel: [1])
        s.fill(PixelRect(x0: -4096, y0: -4096, x1: 4096, y1: 4096), with: [1])
        #expect(s.tileCount == 1024 && s.contentBounds.isEmpty)
        s.prune()
        #expect(s.tileCount == 0)
    }
}

// MARK: - Scoped CMYK converter

/// A converter that answers one fixed colour, so a test can tell which one ran.
struct FixedCMYK: CMYKConverter {
    let rgb: SIMD3<Float>
    let cmyk: SIMD4<Float>
    func cmykToRGB(_ c: SIMD4<Float>) -> SIMD3<Float> { rgb }
    func rgbToCMYK(_ rgb: SIMD3<Float>) -> SIMD4<Float> { cmyk }
}

@Suite(.serialized) struct CMYKScopeTests {
    @Test func scopesNestAndFallBack() {
        let a = FixedCMYK(rgb: SIMD3(1, 0, 0), cmyk: SIMD4(1, 0, 0, 0))
        let b = FixedCMYK(rgb: SIMD3(0, 1, 0), cmyk: SIMD4(0, 1, 0, 0))
        let global = ColorConvert.cmyk
        let outside = ColorConvert.cmykToRGB(SIMD4(0.1, 0.2, 0.3, 0.4))
        ColorConvert.withCMYK(a) {
            #expect(ColorConvert.cmykToRGB(SIMD4(0.1, 0.2, 0.3, 0.4)) == a.rgb)
            #expect(ColorConvert.rgbToCMYK(SIMD3(0.5, 0.5, 0.5)) == a.cmyk)
            #expect(ColorConvert.cmykToRGB(batch: [.zero, .one]) == [a.rgb, a.rgb])
            #expect(ColorConvert.rgbToCMYK(batch: [.zero]) == [a.cmyk])
            ColorConvert.withCMYK(b) { #expect(PCColor(mode: .cmyk, c: .zero).rgb == b.rgb) }
            // nil inside a scope: the process-wide converter again.
            ColorConvert.withCMYK(nil) { #expect(ColorConvert.cmykToRGB(SIMD4(0.1, 0.2, 0.3, 0.4)) == outside) }
            #expect(ColorConvert.activeCMYK is FixedCMYK)
        }
        #expect(ColorConvert.cmykToRGB(SIMD4(0.1, 0.2, 0.3, 0.4)) == outside)
        #expect((ColorConvert.cmyk == nil) == (global == nil), "the process-wide slot is untouched")
    }

    /// Two documents with different CMYK profiles paint at once: each task sees its own converter,
    /// also in the child tasks it starts.
    @Test func parallelTasksKeepTheirOwnConverter() async {
        let a = FixedCMYK(rgb: SIMD3(1, 0, 0), cmyk: SIMD4(0.9, 0, 0, 0))
        let b = FixedCMYK(rgb: SIMD3(0, 0, 1), cmyk: SIMD4(0, 0, 0.9, 0))
        await withTaskGroup(of: Bool.self) { group in
            for (conv, round) in [(a, 0), (b, 1), (a, 2), (b, 3)] {
                group.addTask {
                    await ColorConvert.withCMYK(conv) {
                        var ok = true
                        for i in 0..<200 {
                            var s = Surface(format: .cmyka8)
                            s.writeRGBA(PixelRect(x0: 0, y0: 0, x1: 2, y1: 1), [SIMD4(0.3, 0.6, 0.9, 1), SIMD4(0.1, 0.2, 0.3, 1)])
                            let p = s.pixel(x: 1, y: 0)
                            ok = ok && abs(p[0] - conv.cmyk.x) < 0.01 && abs(p[2] - conv.cmyk.z) < 0.01
                            ok = ok && s.readRGBA(PixelRect(x0: 0, y0: 0, x1: 1, y1: 1))[0] == SIMD4(conv.rgb, 1)
                            if i % 50 == round { await Task.yield() }
                            let child = await Task { ColorConvert.cmykToRGB(.zero) }.value
                            ok = ok && child == conv.rgb
                        }
                        return ok
                    }
                }
            }
            for await ok in group { #expect(ok) }
        }
    }
}

// MARK: - Fast paths against the per-sample code they replaced

/// The per-sample implementations Surface used before the raw-pointer loops.
enum Reference {
    static func readRegion(_ s: Surface, _ r: PixelRect) -> [Float] {
        let ch = s.format.channels
        var out = [Float](repeating: 0, count: r.area * ch)
        var y = r.y0
        while y < r.y1 {
            var x = r.x0
            while x < r.x1 {
                let c = TileCoord(containing: x, y)
                let o = (Int(y - r.y0) * r.width + Int(x - r.x0)) * ch
                if let t = s.tile(c) {
                    let base = ((Int(y) - Int(c.ty) * 256) * 256 + Int(x) - Int(c.tx) * 256) * ch
                    t.bytes.withUnsafeBytes { p in for k in 0..<ch { out[o + k] = readSample(p, s.format.sample, base + k) } }
                } else {
                    let d = s.defaultPixelValue
                    for k in 0..<ch { out[o + k] = d[k] }
                }
                x += 1
            }
            y += 1
        }
        return out
    }

    static func writeRegion(_ s: inout Surface, _ r: PixelRect, _ data: [Float]) {
        let ch = s.format.channels, sample = s.format.sample
        var y = r.y0
        while y < r.y1 {
            var x = r.x0
            while x < r.x1 {
                let c = TileCoord(containing: x, y)
                let base = ((Int(y) - Int(c.ty) * 256) * 256 + Int(x) - Int(c.tx) * 256) * ch
                let o = (Int(y - r.y0) * r.width + Int(x - r.x0)) * ch
                s.withTileBytes(c) { p in for k in 0..<ch { writeSample(p, sample, base + k, data[o + k]) } }
                x += 1
            }
            y += 1
        }
    }

    /// The bounding box of every pixel with a byte unlike the default pixel's, pixel by pixel.
    static func contentBounds(_ s: Surface) -> PixelRect {
        let bpp = s.format.bytesPerPixel
        var (x0, y0, x1, y1) = (Int.max, Int.max, Int.min, Int.min)
        s.forEachTile { c, t in
            t.bytes.withUnsafeBytes { p in
                s.defaultPixel.withUnsafeBytes { d in
                    var i = 0
                    while i < 65_536 {
                        var k = 0
                        while k < bpp, p[i * bpp + k] == d[k] { k += 1 }
                        if k < bpp {
                            let x = Int(c.tx) * 256 + i % 256, y = Int(c.ty) * 256 + i / 256
                            x0 = min(x0, x); x1 = max(x1, x + 1); y0 = min(y0, y); y1 = max(y1, y + 1)
                        }
                        i += 1
                    }
                }
            }
        }
        if x0 == Int.max { return .empty }
        return PixelRect(x0: Int32(clamping: x0), y0: Int32(clamping: y0), x1: Int32(clamping: x1), y1: Int32(clamping: y1))
    }

    static func uniformTiles(_ s: Surface) -> Set<TileCoord> {
        var out = Set<TileCoord>()
        let bpp = s.format.bytesPerPixel
        s.forEachTile { c, t in
            let same = t.bytes.withUnsafeBytes { p in
                s.defaultPixel.withUnsafeBytes { d in
                    var i = 0
                    while i < p.count, p[i] == d[i % bpp] { i += 1 }
                    return i == p.count
                }
            }
            if same { out.insert(c) }
        }
        return out
    }
}

@Suite struct FastPathTests {
    /// Every 8- and 16-bit value decodes as `readSample` does; awkward floats encode as
    /// `writeSample` does.
    @Test func sampleRunsMatchTheSampleCodec() {
        for sample in SampleType.allCases {
            let n = sample == .u8 ? 256 : (sample == .u16 ? 65_536 : 4096)
            var bytes = [UInt8](repeating: 0, count: n * sample.bytes)
            var rng = TestRNG(7)
            for i in 0..<bytes.count { bytes[i] = sample == .f32 ? UInt8(truncatingIfNeeded: rng.next()) : 0 }
            if sample == .u8 { for i in 0..<n { bytes[i] = UInt8(i) } }
            if sample == .u16 { bytes.withUnsafeMutableBytes { p in for i in 0..<n { p.storeBytes(of: UInt16(i), toByteOffset: i * 2, as: UInt16.self) } } }
            var fast = [Float](repeating: 0, count: n)
            bytes.withUnsafeBytes { p in fast.withUnsafeMutableBufferPointer { SampleRun.decode(p.baseAddress!, sample, $0.baseAddress!, n) } }
            let slow = bytes.withUnsafeBytes { p in (0..<n).map { readSample(p, sample, $0) } }
            #expect(zip(fast, slow).allSatisfy { $0.bitPattern == $1.bitPattern }, "\(sample)")
        }
        var vals: [Float] = [0, -0.0, 1, -1, 2, 0.5, 0.49999997, 1.0 / 255, 0.5 / 255, 0.5 / 65535, 254.5 / 255, 65534.5 / 65535,
                             .nan, -.nan, .infinity, -.infinity, .ulpOfOne, .leastNonzeroMagnitude, .greatestFiniteMagnitude, 1.0000001, 0.99999994]
        var rng = TestRNG(11)
        for _ in 0..<20_000 { vals.append(rng.float() * 1.2 - 0.1) }
        for i in 0...255 { vals += [(Float(i) - 0.5) / 255, (Float(i) + 0.5) / 255, Float(i) / 255] }
        for sample in SampleType.allCases {
            var fast = [UInt8](repeating: 0, count: vals.count * sample.bytes)
            var slow = fast
            vals.withUnsafeBufferPointer { v in fast.withUnsafeMutableBytes { SampleRun.encode(v.baseAddress!, sample, $0.baseAddress!, vals.count) } }
            slow.withUnsafeMutableBytes { p in for (i, v) in vals.enumerated() { writeSample(p, sample, i, v) } }
            #expect(fast == slow, "\(sample)")
        }
    }

    @Test func regionsMatchPerSampleReadsAndWrites() {
        var rng = TestRNG(42)
        for fmt in allTestFormats {
            let ch = fmt.channels
            var fast = Surface(format: fmt, defaultPixel: (0..<ch).map { _ in rng.float() })
            var slow = fast
            for _ in 0..<8 {
                let x0 = Int32(rng.int(-300..<500)), y0 = Int32(rng.int(-300..<500))
                let r = PixelRect(x0: x0, y0: y0, x1: x0 + Int32(rng.int(1..<300)), y1: y0 + Int32(rng.int(1..<24)))
                let data = (0..<(r.area * ch)).map { i -> Float in
                    switch i % 97 { case 0: .nan; case 1: -0.3; case 2: 1.7; default: rng.float() }
                }
                fast.writeRegion(r, data)
                Reference.writeRegion(&slow, r, data)
                #expect(fast == slow, "\(fmt) write \(r)")
                let q = r.outset(by: Int32(rng.int(0..<40)))
                let a = fast.readRegion(q), b = Reference.readRegion(slow, q)
                #expect(a.count == b.count && zip(a, b).allSatisfy { $0.bitPattern == $1.bitPattern }, "\(fmt) read \(q)")
                #expect(fast.readInterleaved(q) == slow.readInterleaved(q) && fast.readInterleaved(q).count == q.area * fmt.bytesPerPixel)
                let px = (Int32(rng.int(-400..<800)), Int32(rng.int(-400..<800)))
                #expect(fast.pixel(x: px.0, y: px.1).map(\.bitPattern) == Reference.readRegion(slow, PixelRect(x0: px.0, y0: px.1, x1: px.0 + 1, y1: px.1 + 1)).map(\.bitPattern))
            }
            #expect(fast.contentBounds == Reference.contentBounds(fast), "\(fmt)")
            // Bounds and prune over tiles that are uniform, partly default, or default but for one pixel.
            let def = fast.defaultPixelValue
            fast.fill(PixelRect(x0: 1024, y0: 1024, x1: 1280, y1: 1280), with: def)
            fast.fill(PixelRect(x0: 2048, y0: 0, x1: 2304, y1: 256), with: def)
            fast.setPixel(x: 2303, y: 255, def.map { $0 > 0.5 ? 0 : 1 })
            fast.fill(PixelRect(x0: -2048, y0: 0, x1: -1792, y1: 256), with: def)
            fast.setPixel(x: -2048, y: 0, def.map { $0 > 0.5 ? 0 : 1 })
            #expect(fast.contentBounds == Reference.contentBounds(fast), "\(fmt)")
            let uniform = Reference.uniformTiles(fast)
            var pruned = fast
            pruned.prune()
            #expect(Set(pruned.tileCoords) == Set(fast.tileCoords).subtracting(uniform), "\(fmt)")
            #expect(pruned.contentBounds == fast.contentBounds)
        }
    }

    @Test func floatImageHelpersMatchTheirDefinitions() {
        var rng = TestRNG(5)
        let rect = PixelRect(x0: -3, y0: 4, x1: 9, y1: 11)
        let img = FloatImage(rect: rect, channels: 3, data: (0..<(rect.area * 3)).map { _ in rng.float() })
        for edge in [EdgeMode.transparent, .repeatEdge, .wrap] {
            for _ in 0..<200 {
                let x = rng.float() * 30 - 12, y = rng.float() * 30 - 4
                let fx = x - 0.5, fy = y - 0.5
                let x0 = Int32(fx.rounded(.down)), y0 = Int32(fy.rounded(.down))
                let tx = fx - Float(x0), ty = fy - Float(y0)
                let a = img.sample(x: x0, y: y0, edge: edge), b = img.sample(x: x0 + 1, y: y0, edge: edge)
                let c = img.sample(x: x0, y: y0 + 1, edge: edge), d = img.sample(x: x0 + 1, y: y0 + 1, edge: edge)
                let want = (0..<3).map { k -> Float in
                    let ai = a[a.startIndex + k], bi = b[b.startIndex + k], ci = c[c.startIndex + k], di = d[d.startIndex + k]
                    return (ai * (1 - tx) + bi * tx) * (1 - ty) + (ci * (1 - tx) + di * tx) * ty
                }
                #expect(img.bilinear(x: x, y: y, edge: edge).map(\.bitPattern) == want.map(\.bitPattern))
            }
        }
        // Clamped reads repeat the edge pixels of the extent.
        var s = Surface(format: .rgba32f)
        s.writeRegion(rect, (0..<(rect.area * 4)).map { _ in rng.float() })
        let wide = rect.outset(by: 5)
        let clamped = FloatImage(surface: s, rect: wide, clampedTo: rect)
        for y in wide.y0..<wide.y1 {
            for x in wide.x0..<wide.x1 {
                let sx = min(max(x, rect.x0), rect.x1 - 1), sy = min(max(y, rect.y0), rect.y1 - 1)
                let i = clamped.index(x: x, y: y)
                #expect(Array(clamped.data[i..<i + 4]) == s.pixel(x: sx, y: sy))
            }
        }
        // Mixing by coverage, including NaN and out-of-range coverage.
        let filt = FloatImage(rect: rect, channels: 3, data: img.data.map { 1 - $0 })
        let cov: [Float] = (0..<rect.area).map { i in i % 11 == 0 ? .nan : rng.float() * 1.4 - 0.2 }
        let mixed = img.mixed(with: filt, coverage: cov, hasAlpha: true)
        for i in 0..<rect.area {
            let k = min(max(cov[i], 0), 1), p = i * 3
            for c in 0..<3 {
                let want: Float
                if k >= 1 { want = filt.data[p + c] } else if k <= 0 { want = img.data[p + c] } else {
                    let oa = img.data[p + 2], fa = filt.data[p + 2]
                    if oa != fa {
                        let ma = oa + (fa - oa) * k
                        let ow = oa * (1 - k), fw = fa * k
                        want = c == 2 ? ma : (ma > 0 ? (img.data[p + c] * ow + filt.data[p + c] * fw) / ma : 0)
                    } else {
                        want = img.data[p + c] + (filt.data[p + c] - img.data[p + c]) * k
                    }
                }
                #expect(mixed.data[p + c].bitPattern == want.bitPattern || (mixed.data[p + c].isNaN && want.isNaN))
            }
        }
    }
}

/// `withTransparentDefault(within:)`: an alpha added to an opaque image makes its default opaque, and a solid tile of
/// that colour stops being content (AB-T-0422, AB-T-0423).
@Suite struct TransparentDefaultTests {
    @Test func anOpaqueDefaultBecomesContentInsideTheBounds() {
        // 300 × 200 of opaque black with one grey pixel, made without alpha and pruned, then given an opaque alpha.
        var rgb = Surface(format: PixelFormat(mode: .rgb, sample: .u8, alpha: false))
        let bounds = PixelRect(x0: 0, y0: 0, x1: 300, y1: 200)
        rgb.fill(bounds, with: [0, 0, 0])
        rgb.setPixel(x: 260, y: 150, [0.5, 0.5, 0.5])
        rgb.prune()
        let opaque = rgb.converted(to: PixelFormat(mode: .rgb, sample: .u8, alpha: true))
        #expect(opaque.defaultPixelValue == [0, 0, 0, 1])
        #expect(opaque.contentBounds != bounds)

        let s = opaque.withTransparentDefault(within: bounds)
        #expect(s.defaultPixelValue == [0, 0, 0, 0])
        #expect(s.contentBounds == bounds)
        #expect(s.pixel(x: 0, y: 0) == [0, 0, 0, 1])
        #expect(s.pixel(x: 299, y: 199) == [0, 0, 0, 1])
        #expect(abs(s.pixel(x: 260, y: 150)[0] - 0.5) < 0.01)
        #expect(s.pixel(x: 300, y: 0) == [0, 0, 0, 0])
        #expect(s.pixel(x: 0, y: 200) == [0, 0, 0, 0])
        #expect(s.pixel(x: -1, y: -1) == [0, 0, 0, 0])
        // Whole solid tiles stay shared: a few tiles, not one per tile of the image.
        #expect(s.tileCount <= opaque.tileCount + bounds.tiles.count)
    }

    @Test func aTransparentDefaultComesBackUnchanged() {
        var s = Surface(format: PixelFormat(mode: .rgb, sample: .u8, alpha: true))
        s.fill(PixelRect(x0: 0, y0: 0, x1: 10, y1: 10), with: [1, 0, 0, 1])
        #expect(s.withTransparentDefault(within: PixelRect(x0: 0, y0: 0, x1: 5, y1: 5)) == s)
    }
}

@Suite struct TileCountTests {
    /// photocraft `3729c3f66` `a_surface_bounds_tile_count_is_counted_not_walked`: a rect's tiles are counted without
    /// being visited, and taking tiles from a rect that spans billions answers from the stored ones.
    @Test(.timeLimit(.minutes(1))) func tilesAreCountedNotWalked() {
        #expect(PixelRect.empty.tileCount == 0)
        #expect(PixelRect(x0: 0, y0: 0, x1: 257, y1: 257).tileCount == 4)
        #expect(PixelRect(x0: -1, y0: -1, x1: 1, y1: 1).tileCount == 4)
        let r = PixelRect(x0: 3, y0: -700, x1: 5000, y1: 900)
        #expect(r.tileCount == UInt64(r.tiles.count))
        let everything = PixelRect(x0: .min, y0: .min, x1: .max, y1: .max)
        #expect(everything.tileCount == UInt64(1 << 24) * UInt64(1 << 24))

        var s = Surface(format: .rgba8)
        s.fill(PixelRect(x0: 10, y0: 10, x1: 20, y1: 20), with: [1, 0, 0, 1])
        s.fill(PixelRect(x0: 1_000_000_000, y0: -1_000_000_000, x1: 1_000_000_010, y1: -999_999_990), with: [0, 1, 0, 1])
        let taken = s.takeTiles(everything)
        #expect(taken.count == 2 && s.contentBounds.isEmpty)
        #expect(taken.map(\.0) == taken.map(\.0).sorted { ($0.ty, $0.tx) < ($1.ty, $1.tx) })
    }
}

