// New: compositing at a level of detail from reduced sources (Level/*.swift; AB-T-0256).

import Foundation
import Metal
import PCDocument
import PCFoundation
import Testing
@testable import PCRender

/// How two composites of the same rect differ: premultiplied channels, in 8-bit levels.
struct LevelDiff: CustomStringConvertible {
    var max: Float = 0, mean: Float = 0, over2 = 0.0, over8 = 0.0, pixels = 0
    var description: String {
        String(format: "max %.2f, mean %.3f levels, %.3f%% over 2, %.3f%% over 8 of %d px", max, mean, over2 * 100, over8 * 100, pixels)
    }

    init(_ a: RGBABuffer, _ b: RGBABuffer) {
        precondition(a.px.count == b.px.count, "\(a.rect) vs \(b.rect)")
        var sum = 0.0, o2 = 0, o8 = 0
        for i in a.px.indices {
            let p = a.px[i], q = b.px[i]
            let pa = SIMD4(p.x * p.w, p.y * p.w, p.z * p.w, p.w), pb = SIMD4(q.x * q.w, q.y * q.w, q.z * q.w, q.w)
            var d = (pa - pb) * 255
            for k in 0..<4 { d[k] = d[k].isNaN ? 255 : Swift.abs(d[k]) }
            let m = d.max()
            max = Swift.max(max, m)
            sum += Double(d.sum())
            if m > 2 { o2 += 1 }
            if m > 8 { o8 += 1 }
        }
        pixels = a.px.count
        mean = pixels == 0 ? 0 : Float(sum / Double(pixels * 4))
        over2 = pixels == 0 ? 0 : Double(o2) / Double(pixels)
        over8 = pixels == 0 ? 0 : Double(o8) / Double(pixels)
    }
}

@Suite(.serialized) struct LevelOfDetailTests {
    // MARK: Tile reduction

    /// A random tile of `format` (alpha mostly opaque, some transparent and partial).
    static func randomTile(_ format: PixelFormat, seed: UInt64) -> Tile {
        var rng = Rng(seed)
        let n = Int(tileSize) * Int(tileSize), ch = format.channels
        var v = [Float](repeating: 0, count: n * ch)
        for i in 0..<n {
            let a: Float = { let r = rng.float(); return r < 0.2 ? 0 : (r < 0.5 ? rng.float() : 1) }()
            for k in 0..<ch { v[i * ch + k] = format.alpha && k == ch - 1 ? a : rng.float() }
        }
        var s = Surface(format: format)
        s.writeRegion(PixelRect(x: 0, y: 0, width: Int(tileSize), height: Int(tileSize)), v)
        return s.tile(TileCoord(tx: 0, ty: 0))!
    }

    /// The block mean in doubles from the decoded samples (alpha-weighted colour with alpha).
    static func reference(_ t: Tile, _ format: PixelFormat, level: Int) -> [Double] {
        var s = Surface(format: format)
        s.putTiles([(TileCoord(tx: 0, ty: 0), t)])
        let ts = Int(tileSize), f = 1 << level, o = ts >> level, ch = format.channels
        let v = s.readRegion(PixelRect(x: 0, y: 0, width: ts, height: ts))
        var out = [Double](repeating: 0, count: o * o * ch)
        for oy in 0..<o {
            for ox in 0..<o {
                var sums = [Double](repeating: 0, count: ch), w = 0.0
                for y in (oy * f)..<(oy * f + f) {
                    for x in (ox * f)..<(ox * f + f) {
                        let p = (y * ts + x) * ch
                        if format.alpha {
                            let a = Double(Swift.max(v[p + ch - 1], 0))
                            for k in 0..<(ch - 1) { sums[k] += Double(v[p + k]) * a }
                            sums[ch - 1] += Double(v[p + ch - 1]); w += a
                        } else {
                            for k in 0..<ch { sums[k] += Double(v[p + k]) }
                        }
                    }
                }
                let n = Double(f * f), q = (oy * o + ox) * ch
                for k in 0..<ch {
                    out[q + k] = format.alpha && k < ch - 1 ? (w > 0 ? sums[k] / w : 0) : sums[k] / n
                }
            }
        }
        return out
    }

    @Test(arguments: [PixelFormat.rgba8, .rgba16, .rgba32f, .gray8, .graya8, .gray16, .cmyka8, PixelFormat(mode: .rgb, sample: .u8, alpha: false)])
    func tileReductionIsTheBlockMean(_ format: PixelFormat) {
        let t = Self.randomTile(format, seed: UInt64(format.channels * 31 + format.sample.bytes))
        for level in 1...LevelOfDetail.maxLevel {
            let side = TileReduction.blockSide(level), row = side * format.bytesPerPixel
            var got = [UInt8](repeating: 0, count: side * row)
            got.withUnsafeMutableBytes { d in
                t.bytes.withUnsafeBytes { TileReduction.reduce($0.baseAddress!, format: format, level: level, into: d.baseAddress!, rowBytes: row) }
            }
            let decoded = Surface(format: format, rect: PixelRect(x: 0, y: 0, width: side, height: side), interleaved: got)
                .readRegion(PixelRect(x: 0, y: 0, width: side, height: side))
            let want = Self.reference(t, format, level: level)
            // Integer samples: half a step of rounding (the colour of a near-transparent block a step
            // more: its straight value is a ratio of rounded sums); floats: summation order.
            let tol: Double = switch format.sample { case .u8: 0.5 / 255 + 1e-6; case .u16: 0.5 / 65535 + 1e-7; case .f32: 1e-5 }
            var worst = 0.0
            for i in want.indices { worst = Swift.max(worst, Swift.abs(Double(decoded[i]) - want[i])) }
            #expect(worst <= tol, "\(format) level \(level): \(worst * 255) levels")
        }
    }

    @Test func reducedLeavesReadAsTheSurfaceReduction() {
        // A surface across negative coordinates with a missing tile in the middle, a non-zero default.
        var s = TS.surface(PixelRect(x: -300, y: -40, width: 700, height: 300)) { x, y in
            SIMD4(Float((x & 63)) / 63, Float(y & 31) / 31, 0.5, (x ^ y) & 7 == 0 ? 0 : 0.25 + Float((x + y) & 3) / 4)
        }
        _ = s.takeTiles(PixelRect(x: 0, y: 0, width: 256, height: 256))
        for level in [1, 2, 3, 5] {
            let f = Int32(1 << level)
            let rect = PixelRect(x0: -300 / f - 2, y0: -40 / f - 1, x1: 400 / f + 2, y1: 260 / f + 1)
            let got = RGBABuffer(rect: rect, px: LeafReader.rgba(.reduced(s, level: level), rect))
            // The reference: renderReduced's arithmetic over the document pixels, one layer.
            var d = Document(name: "r", size: PixelSize(width: 1, height: 1), mode: .rgb, depth: .u8)
            d.layers = [Layer.raster("l", surface: s)]
            let docRect = LevelOfDetail.documentRect(rect, level: level)
            let want = try! DT.cpu.renderReduced(d, rect: docRect, width: rect.width, height: rect.height)
            let diff = LevelDiff(got, RGBABuffer(rect: rect, px: want.px))
            // Premultiplied: half a step of straight colour (times alpha) plus half a step of alpha.
            #expect(diff.max <= 1, "level \(level): \(diff)")
            #expect(LeafReader.extent(.reduced(s, level: level)) == LevelOfDetail.region(ContentBounds.of(s), level: level))
        }
        // Masks read as values, their default outside the tiles.
        var m = Surface(format: .gray8, defaultPixel: [1])
        m.fill(PixelRect(x: 0, y: 0, width: 64, height: 64), with: [0])
        let v = LeafReader.values(.reduced(m, level: 2), PixelRect(x: 0, y: 0, width: 32, height: 8))
        #expect(v[0] == 0 && v[15] == 0 && v[16] == 1 && v[31] == 1)
        #expect(LeafReader.outsideValue(.reduced(m, level: 2)) == 1)
    }

    @Test func blocksAreCachedByGeneration() {
        let cache = ReducedTiles(budget: 1 << 30)
        let t = Self.randomTile(.rgba8, seed: 9)
        let a = cache.block(t, format: .rgba8, level: 3)
        #expect(cache.bytes == a.count && cache.cached(t, format: .rgba8, level: 3) == a)
        // A copy keeps the generation (same bytes): served from the cache.
        let copy = t
        #expect(cache.cached(copy, format: .rgba8, level: 3) != nil)
        var changed = t
        changed.bytes[0] ^= 0xff
        #expect(cache.cached(changed, format: .rgba8, level: 3) == nil)
        #expect(cache.trim(.critical) == a.count && cache.bytes == 0)
        // A tight budget keeps the most recent blocks only.
        let small = ReducedTiles(budget: 16 * 64 * 64 * 4 * 2)
        for i in 0..<64 { _ = small.block(Self.randomTile(.rgba8, seed: UInt64(100 + i)), format: .rgba8, level: 2) }
        #expect(small.bytes <= 16 * 64 * 64 * 4 * 2)
    }

    // MARK: Plans at a level

    @Test func plansAtALevelScaleWhatIsInPixels() {
        let shadow = Shadow(common: FxCommon(.multiply, 0.75), distance: 40, size: 24)
        var fx = Effects(enabled: true, items: [.dropShadow(shadow), .stroke(StrokeFx(common: FxCommon(.normal, 1), size: 8, position: .outside,
                                                                                       paint: .color(.rgb(1, 1, 1))))])
        fx.reference = SIMD2(100, 60)
        let spec = EffectsSpec(layerID: 1, effects: fx, shape: LeafID(raw: 7), region: PixelRect(x0: -13, y0: 5, x1: 403, y1: 300),
                               bounds: PixelRect(x0: 10, y0: 20, x1: 390, y1: 280), clip: PixelRect(x0: -13, y0: 5, x1: 403, y1: 300))
        let mask = MaskSpec(pixel: LeafID(raw: 3), density: 0.8, feather: 12, vector: LeafID(raw: 4), vectorFeather: 6)
        let plan = RenderPlan(context: RenderContext(canvas: PixelRect(x: 0, y: 0, width: 1001, height: 500)), ops: [
            .pushTransparent,
            .fill(FillOp(fill: .pattern(PatternFill(name: "p", scale: 2, phase: SIMD2(8, 4))), frame: PixelRect(x0: 3, y0: 6, x1: 403, y1: 205), mask: mask)),
            .composite(LayerBlend()),
            .drawTiles(DrawTiles(leaf: LeafID(raw: 9), mask: mask)),
            .effect(spec, atop: false),
            .drawTiles(DrawTiles(leaf: nil)),
            .restrictTo(PixelRect(x0: 6, y0: 6, x1: 102, y1: 98)),
        ])
        let p = plan.atLevel(2)
        #expect(p.context.canvas == PixelRect(x: 0, y: 0, width: 251, height: 125))
        guard case .fill(let f) = p.ops[1], case .pattern(let pf) = f.fill, case .effect(let e, _) = p.ops[4],
              case .drawTiles(let d) = p.ops[3], case .restrictTo(let r) = p.ops[6] else { Issue.record("ops"); return }
        #expect(f.frame == PixelRect(x0: 1, y0: 2, x1: 101, y1: 51) && pf.scale == 0.5 && pf.phase == SIMD2(2, 1))
        #expect(d.mask?.feather == 3 && d.mask?.vectorFeather == 1.5 && d.mask?.density == 0.8)
        #expect(e.region == PixelRect(x0: -4, y0: 1, x1: 101, y1: 75) && e.clip == e.region && e.bounds == PixelRect(x0: 3, y0: 5, x1: 98, y1: 70))
        guard case .dropShadow(let s2) = e.effects.items[0], case .stroke(let st) = e.effects.items[1] else { Issue.record("effects"); return }
        #expect(s2.distance == 10 && s2.size == 6 && st.size == 2 && e.effects.reference == SIMD2(25, 15))
        #expect(r == PixelRect(x0: 2, y0: 2, x1: 26, y1: 25))
        #expect(LevelOfDetail.region(PixelRect(x0: -5, y0: -8, x1: 9, y1: 8), level: 2) == PixelRect(x0: -2, y0: -2, x1: 3, y1: 2))
    }

    // MARK: Levels against the exact reduction

    /// `renderReduced` at `level` over the blocks covering `region`, as level pixels.
    static func reduced(_ d: Document, _ region: PixelRect, level: Int, _ comp: DocumentCompositor = DT.cpu) throws -> RGBABuffer {
        let r = LevelOfDetail.region(region, level: level)
        let b = try comp.renderReduced(d, rect: LevelOfDetail.documentRect(r, level: level), width: r.width, height: r.height)
        return RGBABuffer(rect: r, px: b.px)
    }

    /// `renderReduced`'s arithmetic on a composite already made (premultiplied block means), over
    /// the level pixels covering `full.rect`, blocks past it transparent.
    static func boxReduce(_ full: RGBABuffer, level: Int) -> RGBABuffer {
        let r = LevelOfDetail.region(full.rect, level: level), f = Int32(1 << level)
        var out = RGBABuffer(transparent: r)
        for j in 0..<r.height {
            for i in 0..<r.width {
                var acc = SIMD4<Float>.zero
                let (lx, ly) = (r.x0 + Int32(i), r.y0 + Int32(j))
                for y in (ly * f)..<(ly * f + f) where y >= full.rect.y0 && y < full.rect.y1 {
                    for x in (lx * f)..<(lx * f + f) where x >= full.rect.x0 && x < full.rect.x1 {
                        let p = full.px[Int(y - full.rect.y0) * full.rect.width + Int(x - full.rect.x0)]
                        acc += SIMD4(p.x * p.w, p.y * p.w, p.z * p.w, p.w)
                    }
                }
                out.px[j * r.width + i] = acc.w > 0 ? SIMD4(acc.x / acc.w, acc.y / acc.w, acc.z / acc.w, acc.w / Float(f * f)) : .zero
            }
        }
        return out
    }

    @Test func aSingleLayerAtALevelIsItsReduction() throws {
        var d = Document(name: "one", size: PixelSize(width: 600, height: 400), mode: .rgb, depth: .u8)
        d.layers = [Layer.raster("blob", surface: TS.blob(PixelRect(x: -20, y: 30, width: 560, height: 360), seed: 3, cx: 260, cy: 210, r: 170,
                                                             opaqueInside: false))]
        for level in 1...4 {
            let want = try Self.reduced(d, d.bounds, level: level)
            let cpu = try DT.cpu.render(d, region: d.bounds, level: level)
            #expect(cpu.rect == want.rect)
            let dc = LevelDiff(cpu, want)
            // One layer over transparency: the composite is the reduced layer (its rounding only).
            #expect(dc.max <= 1, "CPU level \(level): \(dc)")
            if let gpu = DT.gpu {
                let g = try gpu.render(d, region: d.bounds, level: level)
                let dg = LevelDiff(g, want)
                #expect(dg.max <= 1, "GPU level \(level): \(dg)")
            }
        }
    }

    /// Records a level composite against the exact reduction, CPU and GPU, and the GPU against the
    /// CPU level reference. Returns (vs exact, GPU vs CPU).
    @discardableResult
    static func measure(_ d: Document, _ region: PixelRect, level: Int, full: RGBABuffer? = nil, name: String) throws -> (LevelDiff, LevelDiff?) {
        let want = try full.map { boxReduce($0, level: level) } ?? reduced(d, region, level: level)
        let cpu = try DT.cpu.render(d, region: region, level: level)
        let exact = LevelDiff(cpu, want)
        var parity: LevelDiff?
        if let gpu = DT.gpu {
            parity = LevelDiff(try gpu.render(d, region: region, level: level), cpu)
        }
        print("level-of-detail \(name) L\(level): vs renderReduced \(exact); GPU vs CPU \(parity.map(\.description) ?? "-")")
        return (exact, parity)
    }

    /// realistic20 with its layer effects off: masks (one feathered), blend modes, Blend If, clipping,
    /// fills, a type layer and eight adjustment layers.
    @Test func levelsWithoutEffects() throws {
        var d = BenchmarkDocuments.realistic20(size: 1024)
        func off(_ ls: inout [Layer]) {
            for i in ls.indices {
                ls[i].effects.enabled = false
                if case .group(var g) = ls[i].content { off(&g.children); ls[i].content = .group(g) }
            }
        }
        off(&d.layers)
        let full = try DT.cpu.render(d, region: d.bounds)
        for level in 1...3 {
            let (exact, parity) = try Self.measure(d, d.bounds, level: level, full: full, name: "realistic20 without effects")
            // The stated bound (PORT-NOTES.md, "Levels of detail"), measured at most 20.0 / 0.41 / 0.09 %.
            #expect(exact.max <= 24 && exact.mean <= 0.6 && exact.over8 <= 0.003, "L\(level): \(exact)")
            if let parity { #expect(parity.max <= 1.5 * 1.01, "L\(level) GPU vs CPU: \(parity)") }
        }
    }

    @Test func benchmarkScenesAtLevels() throws {
        for d in [BenchmarkDocuments.realistic20(size: 1024), BenchmarkDocuments.effects4(size: 1024)] {
            let full = try DT.cpu.render(d, region: d.bounds)
            for level in 1...3 {
                let (exact, parity) = try Self.measure(d, d.bounds, level: level, full: full, name: d.name)
                // The stated bound (PORT-NOTES.md, "Levels of detail"). At 1024² these scenes' strokes,
                // bevels and shadow offsets are 1.5–8 px, under 2 level pixels from level 2: measured
                // at most 1.13 levels mean, 4.1 % of pixels over 8.
                #expect(exact.mean <= 1.5 && exact.over8 <= 0.05, "\(d.name) L\(level): \(exact)")
                // GPU against the CPU at the same level: the full-resolution bound (≤ 1.5 levels).
                if let parity { #expect(parity.max <= 1.5 * 1.01, "\(d.name) L\(level) GPU vs CPU: \(parity)") }
            }
        }
    }

    @Test func aPartOfTheDocumentAtALevel() throws {
        let d = BenchmarkDocuments.realistic20(size: 1024)
        let region = PixelRect(x0: 192, y0: 64, x1: 832, y1: 704)
        let (exact, parity) = try Self.measure(d, region, level: 2, name: "realistic20 part")
        #expect(exact.mean <= 1.5 && exact.over8 <= 0.05, "\(exact)")
        if let parity { #expect(parity.max <= 1.5 * 1.01, "\(parity)") }
        // A part composites what the whole does there (the plan of the part prunes nothing visible).
        let whole = try DT.cpu.render(d, region: d.bounds, level: 2)
        let part = try DT.cpu.render(d, region: region, level: 2)
        var cut = RGBABuffer(transparent: part.rect)
        cut.px = (0..<part.rect.area).map { i in
            let x = part.rect.x0 + Int32(i % part.rect.width), y = part.rect.y0 + Int32(i / part.rect.width)
            return whole.px[Int(y - whole.rect.y0) * whole.rect.width + Int(x - whole.rect.x0)]
        }
        #expect(LevelDiff(part, cut).max <= 0.01)
    }

    /// Filter adjustment layers (AB-T-0258) at a level: `FilterSpec.atLevel` shrinks the blurs' lengths, Grain reads
    /// its field in document units and Add Noise averages down. GPU against CPU at the level, and against the exact
    /// reduction.
    @Test(arguments: FilterFixtures.kinds.map(\.0))
    func filterLayersAtALevel(_ name: String) throws {
        let f = try #require(FilterFixtures.kinds.first { $0.0 == name }?.1)
        var d = FilterFixtures.doc(.u8, w: 512, h: 384)
        d.layers.append(FilterFixtures.layer(f))
        let full = try DT.cpu.render(d, region: d.bounds)
        for level in [1, 2] {
            let cpu = try DT.cpu.render(d, region: d.bounds, level: level)
            let exact = LevelDiff(cpu, Self.boxReduce(full, level: level))
            var parity: LevelDiff?
            if let gpu = DT.gpu { parity = LevelDiff(try gpu.render(d, region: d.bounds, level: level), cpu) }
            print("level-of-detail filter \(name) L\(level): vs renderReduced \(exact); GPU vs CPU \(parity.map(\.description) ?? "-")")
            if let parity { #expect(parity.max <= 1.5, "\(name) L\(level) GPU vs CPU: \(parity)") }
            if f.samplesNeighbours {
                // A blur's lengths shrink with the level: Gaussian blurs measured at most 1.65 levels mean; motion blurs,
                // resampled along their direction on the coarser grid, at most 5.44 (−60°, 5 px over 7–13 px stripes, level 2).
                #expect(exact.mean <= 6, "\(name) L\(level): \(exact)")
            } else {
                // Grain and Add Noise draw fresh samples at the level with the spread an average of them has: no pixel
                // matches, and the mean is kept (the signed difference, per channel) but where the noise clips: the exact
                // reduction averages clipped samples, the level clips fewer (measured up to 17.2 levels, in this
                // fixture's near-white blue under Add Noise 120 % Gaussian).
                let limit = 20.0
                let want = Self.boxReduce(full, level: level)
                var bias = SIMD4<Double>.zero
                for i in cpu.px.indices {
                    let a = cpu.px[i], b = want.px[i]
                    bias += SIMD4<Double>(SIMD4(a.x * a.w - b.x * b.w, a.y * a.w - b.y * b.w, a.z * a.w - b.z * b.w, a.w - b.w))
                }
                let m = bias / Double(cpu.px.count) * 255
                #expect(Swift.max(Swift.abs(m.x), Swift.abs(m.y), Swift.abs(m.z), Swift.abs(m.w)) <= limit, "\(name) L\(level) bias \(m)")
                #expect(Swift.max(Swift.abs(m.x), Swift.abs(m.y), Swift.abs(m.w)) <= 2, "\(name) L\(level) bias off the clipping channel \(m)")
            }
        }
    }

    @Test func nativeDocumentsCompositeAtALevel() throws {
        var d = DT.docWhite(512, 384, mode: .cmyk)
        d.layers.append(DT.solidLayer("c", DT.rect(40, 30, 300, 200), SIMD4(0.2, 0.6, 0.9, 0.8), format: .cmyka8))
        d.layers[1].blend = .multiply
        let want = try Self.reduced(d, d.bounds, level: 2)
        let cpu = try DT.cpu.render(d, region: d.bounds, level: 2)
        // Inks averaged, then converted for display: the conversion bends a mixed edge pixel a little.
        #expect(LevelDiff(cpu, want).max <= 4, "\(LevelDiff(cpu, want))")
        if let gpu = DT.gpu {
            #expect(LevelDiff(try gpu.render(d, region: d.bounds, level: 2), cpu).max <= 1.5)
            let t = try gpu.renderMetal(d, region: d.bounds, level: 2)
            #expect(t.rect == LevelOfDetail.region(d.bounds, level: 2))
        }
    }

    @Test func effectShapesAreBuiltAtTheLevel() throws {
        let d = BenchmarkDocuments.effects4(size: 512)
        let p = DT.cpu.plan(d, region: d.bounds)
        // A compositor of its own: a shared one may hold these maps already and never ask for shapes.
        _ = try CPUCompositor().render(p.plan, region: d.bounds, level: 2, source: p.source)
        let shapes = p.source.derived.filter { $0.key.raw & 0xff == UInt64(LeafRole.effectShape.rawValue) }
        #expect(!shapes.isEmpty)
        for (_, s) in shapes {
            #expect(s.value == nil, "no full-resolution shape was built")
            if case .image(let img, _, _)? = s.levels[2] {
                #expect(img.rect.width <= 512 / 4 + 64, "\(img.rect)")
            } else {
                Issue.record("no level shape")
            }
        }
    }

    @Test func sampledPreviewsShowTheBlockCentres() throws {
        var d = Document(name: "one", size: PixelSize(width: 600, height: 400), mode: .rgb, depth: .u8)
        d.layers = [Layer.raster("blob", surface: TS.blob(PixelRect(x: -20, y: 30, width: 560, height: 360), seed: 7, cx: 260, cy: 210, r: 170,
                                                             opaqueInside: false))]
        let full = try DT.cpu.render(d, region: d.bounds)
        for level in [2, 5] {
            let f = Int32(1 << level)
            let p = DT.cpu.plan(d, region: d.bounds)
            let cpu = try DT.cpu.cpu.render(p.plan, region: d.bounds, level: level, sampled: true, source: p.source)
            var want = RGBABuffer(transparent: cpu.rect)
            for j in 0..<cpu.rect.height {
                for i in 0..<cpu.rect.width {
                    let (x, y) = ((cpu.rect.x0 + Int32(i)) * f + f / 2, (cpu.rect.y0 + Int32(j)) * f + f / 2)
                    if full.rect.contains(x: x, y: y) { want.px[j * cpu.rect.width + i] = full.px[Int(y) * full.rect.width + Int(x)] }
                }
            }
            #expect(LevelDiff(cpu, want).max <= 0.01, "CPU level \(level): \(LevelDiff(cpu, want))")
            if let gpu = DT.gpu?.metal {
                let g = try gpu.renderBuffer(p.plan, region: d.bounds, level: level, sampled: true, source: p.source)
                #expect(LevelDiff(g, want).max <= 0.5, "GPU level \(level): \(LevelDiff(g, want))")
                // The averaged level is another set of pages.
                let a = try gpu.renderBuffer(p.plan, region: d.bounds, level: level, source: p.source)
                #expect(LevelDiff(a, try DT.cpu.render(d, region: d.bounds, level: level)).max <= 1)
            }
        }
        // A whole scene's preview: GPU against the CPU.
        let r20 = BenchmarkDocuments.realistic20(size: 1024)
        if let gpu = DT.gpu {
            let p = gpu.plan(r20, region: r20.bounds)
            let g = try gpu.metal!.renderBuffer(p.plan, region: r20.bounds, level: 3, sampled: true, source: p.source)
            let c = try DT.cpu.cpu.render(DT.cpu.plan(r20, region: r20.bounds).plan, region: r20.bounds, level: 3, sampled: true,
                                          source: DT.cpu.plan(r20, region: r20.bounds).source)
            #expect(LevelDiff(g, c).max <= 1.5, "\(LevelDiff(g, c))")
        }
    }

    @Test func theGPURendersEffectShapesItself() throws {
        guard let metal = try? MetalCompositor(chunkSize: 512) else { return }
        let gpu = DocumentCompositor(rasterizer: DT.rasterizer, backend: .metal, metal: metal)
        // Shadows, a stroke (its distance fields read the shape back), a glow, a smooth bevel.
        let d = BenchmarkDocuments.effects4(size: 512)
        for level in [0, 2] {
            let p = gpu.plan(d, region: d.bounds)
            let g = try metal.renderBuffer(p.plan, region: d.bounds, level: level, source: p.source)
            let shapes = p.source.derived.filter { $0.key.raw & 0xff == UInt64(LeafRole.effectShape.rawValue) }
            #expect(shapes.count == 3)
            for (_, s) in shapes { #expect(s.value == nil && s.levels.isEmpty, "no CPU shape at level \(level)") }
            let c = try DT.cpu.render(d, region: d.bounds, level: level)
            #expect(LevelDiff(g, c).max <= 1.5, "level \(level): \(LevelDiff(g, c))")
        }
    }

    /// Effect maps and feathered masks are built over what a render can see (MetalEffects.swift): a region cutting
    /// through layers with shadows, strokes, glows, bevels and a feathered mask comes out as the whole render has it.
    @Test func effectMapsOfARegionAreTheWholeLayersThere() throws {
        guard let metal = try? MetalCompositor(chunkSize: 256) else { return }
        let gpu = DocumentCompositor(rasterizer: DT.rasterizer, backend: .metal, metal: metal)
        for d in [BenchmarkDocuments.effects4(size: 1024), BenchmarkDocuments.realistic20(size: 1024)] {
            for level in [0, 2] {
                let whole = try gpu.render(d, region: d.bounds, level: level)
                for part in [PixelRect(x: 96, y: 160, width: 256, height: 192), PixelRect(x: 384, y: 512, width: 320, height: 256),
                             PixelRect(x: 640, y: 64, width: 256, height: 256)] {
                    let got = try gpu.render(d, region: part, level: level)
                    var want = RGBABuffer(transparent: got.rect)
                    for j in 0..<got.rect.height {
                        for i in 0..<got.rect.width {
                            let (x, y) = (got.rect.x0 + Int32(i) - whole.rect.x0, got.rect.y0 + Int32(j) - whole.rect.y0)
                            want.px[j * got.rect.width + i] = whole.px[Int(y) * whole.rect.width + Int(x)]
                        }
                    }
                    let diff = LevelDiff(got, want)
                    #expect(diff.max <= 0.51, "\(d.name) level \(level) \(part): \(diff)")
                }
            }
        }
    }

    // MARK: Metal level pages

    @Test func levelPagesFollowTileGenerations() throws {
        guard let metal = try? MetalCompositor(chunkSize: 256) else { return }
        let gpu = DocumentCompositor(rasterizer: DT.rasterizer, backend: .metal, metal: metal)
        var d = BenchmarkDocuments.realistic20(size: 1024)
        let p0 = gpu.plan(d, region: d.bounds)
        _ = try metal.render(p0.plan, region: d.bounds, level: 2, source: p0.source)
        let cold = metal.residency.blocksReduced
        #expect(cold > 0)
        // Warm: nothing reduced again.
        let p1 = gpu.plan(d, region: d.bounds)
        _ = try metal.render(p1.plan, region: d.bounds, level: 2, source: p1.source)
        #expect(metal.residency.blocksReduced == cold)
        // One tile of one layer changes: its block alone is reduced again.
        let id = d.layers[1].id
        d.withRaster(of: id) { $0.fill(PixelRect(x: 300, y: 40, width: 20, height: 20), with: [1, 0, 0, 1]) }
        let p2 = gpu.plan(d, region: d.bounds)
        let r2 = try metal.renderBuffer(p2.plan, region: d.bounds, level: 2, source: p2.source)
        #expect(metal.residency.blocksReduced == cold + 1)
        #expect(LevelDiff(r2, try DT.cpu.render(d, region: d.bounds, level: 2)).max <= 1.5)
    }

    @Test func aLevelRenderLandsAtAnOriginOfItsTarget() throws {
        guard let metal = DT.gpu?.metal else { return }
        let d = BenchmarkDocuments.realistic20(size: 512)
        let whole = try #require(DT.gpu).renderMetal(d, region: d.bounds, level: 1, outputStorage: .shared)
        let target = try #require(metal.context.makeTexture(width: 256, height: 256, pixelFormat: .rgba32Float, usage: [.shaderRead, .shaderWrite], storage: .shared))
        for half in [PixelRect(x: 0, y: 0, width: 512, height: 256), PixelRect(x: 0, y: 256, width: 512, height: 256)] {
            let p = DT.gpu!.plan(d, region: half)
            let r = try metal.render(p.plan, region: half, level: 1, source: p.source, into: target, at: SIMD2(0, Int(half.y0) / 2))
            #expect(r.texture === target && r.rect == LevelOfDetail.region(half, level: 1))
        }
        let a = RGBABuffer(metal.context.readImage(whole.texture, rect: PixelRect(x: 0, y: 0, width: 256, height: 256), channels: 4))
        let b = RGBABuffer(metal.context.readImage(target, rect: PixelRect(x: 0, y: 0, width: 256, height: 256), channels: 4))
        #expect(LevelDiff(a, b).max <= 0.01, "\(LevelDiff(a, b))")
    }

    @Test func levelPagesReportAndShedLikePages() throws {
        guard let metal = try? MetalCompositor(chunkSize: 256), let canvas = try? CanvasRenderer() else { return }
        let gpu = DocumentCompositor(rasterizer: DT.rasterizer, backend: .metal, metal: metal)
        let d = BenchmarkDocuments.realistic20(size: 1024)
        // Off view: the whole document at full resolution, then at level 1.
        let all = gpu.plan(d, region: d.bounds)
        _ = try metal.render(all.plan, region: d.bounds, source: all.source)
        _ = try metal.render(all.plan, region: d.bounds, level: 1, source: all.source)
        // The view: level 2.
        let p = gpu.plan(d, region: d.bounds)
        let r = try metal.render(p.plan, region: d.bounds, level: 2, source: p.source, outputFormat: .rgba16Float, view: canvas.renderView)
        try canvas.setComposite(r.texture, rect: r.rect)
        let before = metal.footprint
        #expect(before.levelPages > 0 && before.levelPages < before.pages)
        #expect(before.visiblePages > 0 && before.visiblePages <= before.levelPages + before.leafImages)
        metal.relieve(.offscreen)
        let after = metal.footprint
        // What is left is the view's: its level-2 pages and images; full-resolution and level-1 pages went.
        #expect(after.visiblePages == before.visiblePages && after.pages + after.leafImages == after.visiblePages)
        #expect(after.levelPages == after.pages)
        // The next frame at the level uploads nothing.
        let blocks = metal.residency.blocksReduced
        let p2 = gpu.plan(d, region: d.bounds)
        _ = try metal.render(p2.plan, region: d.bounds, level: 2, source: p2.source, outputFormat: .rgba16Float, view: canvas.renderView)
        #expect(metal.residency.blocksReduced == blocks)
        metal.pressureCleared()
    }

    @Test func aViewDrawnInPartsKeepsEveryPartVisible() throws {
        guard let metal = try? MetalCompositor(chunkSize: 256), let canvas = try? CanvasRenderer() else { return }
        let gpu = DocumentCompositor(rasterizer: DT.rasterizer, backend: .metal, metal: metal)
        let d = BenchmarkDocuments.realistic20(size: 1024)
        let halves = [PixelRect(x: 0, y: 0, width: 1024, height: 512), PixelRect(x: 0, y: 512, width: 1024, height: 512)]
        func draw(adding: Bool) throws -> CompositorFootprint {
            for (i, h) in halves.enumerated() {
                let p = gpu.plan(d, region: h)
                _ = try metal.render(p.plan, region: h, level: 1, source: p.source, outputFormat: .rgba16Float, view: canvas.renderView,
                                     addingToView: adding && i > 0)
            }
            return metal.footprint
        }
        let parts = try draw(adding: true)
        let whole = gpu.plan(d, region: d.bounds)
        _ = try metal.render(whole.plan, region: d.bounds, level: 1, source: whole.source, outputFormat: .rgba16Float, view: canvas.renderView)
        let one = metal.footprint
        // Every page either part bound is visible, as the whole render's are. (Effect maps are each part's own: a
        // render's maps cover what it can see.)
        #expect(parts.visiblePages == one.visiblePages, "\(parts.visiblePages) vs \(one.visiblePages)")
        #expect(parts.visibleEffects > 0)
        let lastOnly = try draw(adding: false)
        #expect(lastOnly.visiblePages < parts.visiblePages && lastOnly.visibleEffects < parts.visibleEffects)
    }

    // MARK: The display chain off the main thread

    /// A shared rgba16Float texture of `f(x, y)`.
    static func halfTexture(_ ctx: MetalContext, _ w: Int, _ h: Int, _ f: (Int, Int) -> SIMD4<Float>) -> (any MTLTexture)? {
        guard let t = ctx.makeTexture(width: w, height: h, pixelFormat: .rgba16Float, usage: [.shaderRead, .shaderWrite], storage: .shared) else { return nil }
        var px = [Float16]()
        for y in 0..<h { for x in 0..<w { let v = f(x, y); px += [Float16(v.x), Float16(v.y), Float16(v.z), Float16(v.w)] } }
        px.withUnsafeBytes { t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: w * 8) }
        return t
    }

    /// The halves of a (private) rgba16Float texture.
    static func halves(_ ctx: MetalContext, _ t: any MTLTexture) -> [Float16] {
        guard let shared = ctx.makeTexture(width: t.width, height: t.height, pixelFormat: .rgba16Float, usage: [.shaderRead], storage: .shared),
              let cb = ctx.queue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() else { return [] }
        blit.copy(from: t, to: shared)
        blit.endEncoding(); cb.commit(); cb.waitUntilCompleted()
        var out = [Float16](repeating: 0, count: t.width * t.height * 4)
        out.withUnsafeMutableBytes { shared.getBytes($0.baseAddress!, bytesPerRow: t.width * 8, from: MTLRegionMake2D(0, 0, t.width, t.height), mipmapLevel: 0) }
        return out
    }

    @Test func aChainUpdatedWhereTheCompositeChangedIsTheWholeChain() throws {
        guard let ctx = MetalContext.shared, let a = try? CanvasRenderer(context: ctx), let b = try? CanvasRenderer(context: ctx) else { return }
        var rng = Rng(5)
        let noise = (0..<(301 * 203)).map { _ in SIMD4(rng.float(), rng.float(), rng.float(), rng.float()) }
        let t = try #require(Self.halfTexture(ctx, 301, 203) { x, y in noise[y * 301 + x] })
        let rect = PixelRect(x: 7, y: 3, width: 301, height: 203)
        // Without a chain, then the whole chain on a command buffer of ours.
        try a.setComposite(t, rect: rect, chainInto: nil)
        #expect(a.levels.isEmpty && a.composite === t && a.compositeRect == rect)
        guard let cb = ctx.queue.makeCommandBuffer(), let cb2 = ctx.queue.makeCommandBuffer(), let cb3 = ctx.queue.makeCommandBuffer() else { return }
        try a.updateChain(into: cb)
        cb.commit(); cb.waitUntilCompleted()
        // A change inside the composite, then the chain where it changed.
        let change = PixelRect(x0: 41, y0: 30, x1: 97, y1: 71)
        var px = [Float16]()
        for _ in 0..<change.area { px += [1, 0, 0.5, 0.75] }
        px.withUnsafeBytes { t.replace(region: MTLRegionMake2D(41, 30, change.width, change.height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: change.width * 8) }
        try a.updateChain(into: cb2, damage: change)
        cb2.commit(); cb2.waitUntilCompleted()
        // Against a chain made whole from the changed composite.
        try b.setComposite(t, rect: rect)
        #expect(a.levels.count == b.levels.count && a.levels.count >= 8)
        for (la, lb) in zip(a.levels, b.levels) {
            #expect(Self.halves(ctx, la) == Self.halves(ctx, lb), "\(la.width)×\(la.height)")
        }
        // A composite of the same size keeps the chain's textures.
        let first = a.levels[0]
        try a.setComposite(t, rect: rect, chainInto: cb3)
        #expect(a.levels[0] === first)
    }
}
