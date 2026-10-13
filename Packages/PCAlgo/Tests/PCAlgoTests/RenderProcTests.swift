// Port of photocraft-algo (crates/algo/src/render2.rs tests) and photocraft-engine (crates/engine/src/render_cmds.rs tests), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Primitive lists are checked against independently derived numbers (SplitMix64 outputs computed
// outside Swift, primitive counts and positions worked out from the formulas by hand), and the
// Metal rasterisation against the CPU's bit for bit.

import Foundation
import Testing
@testable import PCAlgo
import PCFoundation

enum RPFix {
    static let canvas = PixelRect(x0: 0, y0: 0, x1: 400, y1: 300)
    static var backends: [Backend] { AlgoGPU.isAvailable ? [.cpu, .gpu] : [.cpu] }

    static func surface(_ mode: ColorMode = .rgb, _ sample: SampleType = .u8, alpha: Bool = true, rect: PixelRect = PixelRect(x: 0, y: 0, width: 160, height: 120),
                        fill: [Float]? = nil) -> Surface {
        var s = Surface(format: PixelFormat(mode: mode, sample: sample, alpha: alpha))
        if let fill { s.writeRegion(rect, [Float]((0..<rect.area).flatMap { _ in fill })) }
        return s
    }

    static func opaque(_ s: Surface, _ r: PixelRect) -> Int {
        let ch = s.channels
        let v = s.readRegion(r)
        return (0..<r.area).filter { v[$0 * ch + ch - 1] > 0.05 }.count
    }

    static func flamePrims(_ spec: FlameSpec = FlameSpec(), _ c: PixelRect) -> [RenderProc.Prim] {
        RenderProc.flame(spec, paths: [RenderProc.defaultFlamePath(c)])
    }
}

@Suite struct RenderProcPrimitiveTests {
    /// SplitMix64 outputs computed independently (Python, 64-bit wrapping arithmetic).
    @Test func rngMatchesSplitMix64() {
        var r = RenderProc.Rng(seed: 0, salt: 0xF1A3)
        #expect([r.nextU64(), r.nextU64(), r.nextU64()] == [0x1603_b847_80c0_63ee, 0x0493_2919_ff53_86b1, 0xdda5_464a_4502_4b0a])
        var q = RenderProc.Rng(seed: 7, salt: 0x7EE + 1)
        #expect([q.f(), q.f(), q.f(), q.f()] == [0.5666512846946716, 0.9388769865036011, 0.08545148372650146, 0.5288844108581543])
        var m = RenderProc.Rng(seed: .max, salt: 0xF8A3E + 16)
        #expect([m.nextU64(), m.nextU64()] == [0xa51c_ff99_c7d2_2621, 0xf755_1c7b_ceef_a7f4])
    }

    @Test func spineWalksArcLengthLikeRust() {
        let s = RenderProcKit.Spine([SIMD2(0, 0), SIMD2(10, 0), SIMD2(10, 10)])
        #expect(s.len == 20)
        #expect(s.at(5).0 == SIMD2(5, 0) && s.at(5).1 == SIMD2(1, 0))
        #expect(s.at(15).0 == SIMD2(10, 5) && s.at(15).1 == SIMD2(0, 1))
        // An exact hit on a joint takes the following segment (Rust's `Ok(i)`).
        #expect(s.at(10).0 == SIMD2(10, 0) && s.at(10).1 == SIMD2(0, 1))
        #expect(s.at(-3).0 == SIMD2(0, 0) && s.at(99).0 == SIMD2(10, 10))
        // Duplicate arc lengths resolve as Rust's branchless binary search does (the last of the run).
        #expect(RenderProcKit.binarySearch([0, 5, 5, 10], 5) == (true, 2))
        #expect(RenderProcKit.binarySearch([0, 5, 5, 10], 7) == (false, 3))
        #expect(RenderProcKit.binarySearch([0, 5, 5, 10], 0) == (true, 0))
        #expect(RenderProcKit.Spine([SIMD2(3, 4)]).at(9) == (SIMD2(3, 4), SIMD2(0, -1)))
    }

    @Test func powiIsCompilerRTs() {
        let a: Float = 0.72
        #expect(RenderProcKit.powi(a, 0) == 1 && RenderProcKit.powi(a, 1) == a && RenderProcKit.powi(a, 2) == a * a)
        #expect(RenderProcKit.powi(a, 4) == (a * a) * (a * a))
        #expect(RenderProcKit.powi(a, 5) == a * ((a * a) * (a * a)))
    }

    @Test func defaultFlamePathEndpoints() {
        let p = RenderProc.defaultFlamePath(RPFix.canvas)
        #expect(p.count == 33)
        #expect(abs(p[0].x - 60) < 1e-4 && abs(p[0].y - 240) < 1e-4)
        #expect(abs(p[32].x - 340) < 1e-4 && abs(p[32].y - 240) < 1e-4)
        #expect(abs(p[16].y - 216) < 1e-4)  // 300 · (0.8 − 0.08)
    }

    /// photocraft `renderers_are_deterministic_and_seeded`.
    @Test func renderersAreDeterministicAndSeeded() {
        let c = RPFix.canvas
        let a = RenderProc.tree(TreeSpec(), canvas: c)
        #expect(a == RenderProc.tree(TreeSpec(), canvas: c))
        var s7 = TreeSpec()
        s7.seed = 7
        #expect(a != RenderProc.tree(s7, canvas: c))
        for k in UInt32(1)...34 {
            var s = TreeSpec()
            s.baseTreeType = k
            #expect(!RenderProc.tree(s, canvas: c).isEmpty, "tree \(k)")
        }
        for k in 1...UInt32(RenderProc.frameStyles.count) {
            var s = FrameSpec()
            s.frame = k
            #expect(!RenderProc.pictureFrame(s, canvas: c).isEmpty, "frame \(k)")
        }
        for t in FlameType.allCases {
            var s = FlameSpec()
            s.flameType = t
            #expect(!RPFix.flamePrims(s, c).isEmpty, "\(t)")
        }
        #expect(RenderProc.treeTypeNames.count == 34 && RenderProc.treeTypeNames[6] == "Cherry Blossom" && RenderProc.treeTypeNames[33] == "Cloud Pine")
    }

    /// Flame primitive counts from the formulas: 15 lines (20 · 0.6 + 3); the default 400 × 300
    /// path is 285.0 px long, so one flame has max(16, ⌊285 / 12⌋) = 23 segments per line and
    /// 6 glow ellipses; flames along the path are 5 (⌊285 / 60⌋ + 1) of 150 px (16 segments).
    @Test func flamePrimitiveCounts() {
        func count(_ t: FlameType) -> Int {
            var s = FlameSpec()
            s.flameType = t
            return RPFix.flamePrims(s, RPFix.canvas).count
        }
        #expect(count(.oneFlameAlongPath) == 6 + 15 * 23)
        #expect(count(.candleLight) == 6 + 15 * 16 + 1)
        for t in [FlameType.multipleFlamesAlongPath, .multipleFlamesPathDirections, .multipleFlamesVariousLength, .multipleFlamesOneDirection] {
            #expect(count(t) == 5 * (6 + 15 * 16), "\(t)")
        }
        // Blend modes: glows add, strands lighten; the candle core adds.
        let one = RPFix.flamePrims(FlameSpec(), RPFix.canvas)
        #expect(one.prefix(6).allSatisfy { $0.blend == .add } && one.dropFirst(6).allSatisfy { $0.blend == .lighten })
        // A one-point path draws a candle; an empty path nothing.
        #expect(RenderProc.flame(FlameSpec(), paths: [[SIMD2(50, 50)]]).count == 6 + 15 * 16 + 1)
        #expect(RenderProc.flame(FlameSpec(), paths: [[]]).isEmpty)
    }

    /// Tree counts that don't depend on the random stream: palms (12 trunk rings, 10 frond
    /// segments each with a rib and 2 × 2 leaflets at 50 % leaves) and bamboo (5 stalks × 8 joints
    /// × 2 capsules, 2 leaves on each of the upper 6 joints).
    @Test func treePrimitiveCounts() {
        func count(_ k: UInt32) -> Int {
            var s = TreeSpec()
            s.baseTreeType = k
            return RenderProc.tree(s, canvas: RPFix.canvas).count
        }
        #expect(count(4) == 12 + 9 * 10 * 5)        // Palm
        #expect(count(19) == 12 + 7 * 10 * 5)       // Banana
        #expect(count(31) == 12 + 11 * 10 * 5 + 4)  // Coconut Palm (+ 4 coconuts)
        #expect(count(8) == 5 * 8 * 2 + 5 * 6 * 2)  // Bamboo
        // The palm's trunk starts at the base: (0.5, 0.95) of the canvas, heading up.
        var s = TreeSpec()
        s.baseTreeType = 4
        let palm = RenderProc.tree(s, canvas: RPFix.canvas)
        guard case .capsule(let a, let b, _, _) = palm[0].shape else { Issue.record("trunk"); return }
        #expect(a == SIMD2(200, 285))
        #expect(abs(b.x - 200) < 1e-3 && abs(b.y - (285 - 240 * 0.85 / 12)) < 1e-3)
    }

    /// Frame counts at 400 × 300: unit 9.9, spacing 23.76, border 1224.8 px → 52 ornaments; the
    /// vine has ⌈1224.8 / 3⌉ = 409 segments, line designs ⌈1224.8 / 2⌉ = 613.
    @Test func framePrimitiveCounts() {
        let expected: [String: Int] = [
            "vineWithFlowers": 409 + 52 + 26 * 6, "vineWithLeaves": 409 + 52 * 2, "ivy": 409 + 52 * 3, "roses": 409 + 52 + 18 * 4,
            "daisies": 409 + 52 + 26 * 13, "berries": 409 + 52 * 4, "bamboo": 2 * (7 + 5 + 7 + 5) + (3 + 2 + 3 + 2), "waves": 613, "zigzag": 613,
            "dots": 52, "rope": 307, "scallops": 52 * 8, "doubleLine": 613 + 4 + 4, "snowflakes": 52 * 18, "stars": 52 * 5, "hearts": 52 * 2,
        ]
        for (i, name) in RenderProc.frameStyles.enumerated() {
            var s = FrameSpec()
            s.frame = UInt32(i + 1)
            #expect(RenderProc.pictureFrame(s, canvas: RPFix.canvas).count == expected[name], "\(name)")
        }
        // The vine starts at the frame's top-left corner (margin 12 + unit 9.9 inside).
        let v = RenderProc.pictureFrame(FrameSpec(), canvas: RPFix.canvas)
        guard case .capsule(let a, _, let r, _) = v[0].shape else { Issue.record("vine"); return }
        #expect(abs(a.x - 21.9) < 1e-4 && abs(a.y - 21.9) < 1e-4 && abs(r - 1.476) < 1e-5)
        // Three lines triple the line designs; fade lowers inner alphas only.
        var three = FrameSpec()
        three.frame = 8
        three.lines = 3
        #expect(RenderProc.pictureFrame(three, canvas: RPFix.canvas).count == 3 * 613)
        var faded = FrameSpec()
        faded.fade = 100
        let f = RenderProc.pictureFrame(faded, canvas: RPFix.canvas)
        #expect(f.count == v.count && zip(f, v).allSatisfy { $0.c0.w <= $1.c0.w } && zip(f, v).contains { $0.c0.w < $1.c0.w })
    }

    @Test func boundsAndEval() {
        let d = RenderProc.Prim.disc(SIMD2(20, 20), 8, SIMD4(1, 0, 0, 1))
        #expect(d.bounds == PixelRect(x0: 10, y0: 10, x1: 30, y1: 30))
        #expect(d.eval(20.5, 20.5, d.sinCos).0 == 1 && d.eval(40, 40, d.sinCos).0 == 0)
        let c = RenderProc.Prim.capsule(SIMD2(0, 0), SIMD2(10, 0), 2, 1, SIMD4(1, 1, 1, 1), SIMD4(0, 0, 0, 1))
        #expect(c.bounds == PixelRect(x0: -4, y0: -4, x1: 14, y1: 4))
        let (cov, t) = c.eval(5, 0.5, c.sinCos)
        #expect(cov == 1 && t == 0.5)
        // Rust's f32::min/max ignore NaN (so a NaN end alone stays bounded); an infinite one empties.
        #expect(!RenderProc.Prim.capsule(SIMD2(.nan, 0), SIMD2(1, 1), 1, 1, .zero, .zero).bounds.isEmpty)
        #expect(RenderProc.Prim.capsule(SIMD2(.infinity, 0), SIMD2(1, 1), 1, 1, .zero, .zero).bounds.isEmpty)
    }

    @Test func specsDecodeWithDefaults() throws {
        let dec = JSONDecoder()
        let f = try dec.decode(FlameSpec.self, from: Data(#"{"flameType":"candleLight","color":[1,0,0,1]}"#.utf8))
        #expect(f.flameType == .candleLight && f.color == SIMD4(1, 0, 0, 1) && f.length == 150 && f.quality == 2 && f.adjustIntervalForLoops)
        #expect(try dec.decode(FlameSpec.self, from: Data("{}".utf8)) == FlameSpec())
        let t = try dec.decode(TreeSpec.self, from: Data(#"{"baseTreeType":7,"seed":3}"#.utf8))
        #expect(t.baseTreeType == 7 && t.seed == 3 && t.leavesAmount == 50 && t.y == 0.95)
        let fr = try dec.decode(FrameSpec.self, from: Data(#"{"frame":13,"lines":3}"#.utf8))
        #expect(fr.frame == 13 && fr.lines == 3 && fr.margin == 4)
        #expect(try dec.decode(FrameSpec.self, from: JSONEncoder().encode(fr)) == fr)
    }
}

@Suite struct RenderProcCompositeTests {
    /// photocraft `composite_draws_a_disc_and_respects_the_clip`.
    @Test func compositeDrawsADiscAndRespectsTheClip() throws {
        for be in RPFix.backends {
            var s = RPFix.surface()
            let used = try RenderProc.composite(&s, [.disc(SIMD2(20, 20), 8, SIMD4(1, 0, 0, 1))], clip: PixelRect(x0: 0, y0: 0, x1: 20, y1: 40), on: be)
            #expect(used.x1 == 20)
            let c = s.pixel(x: 18, y: 20)
            #expect(c[0] > 0.99 && c[3] > 0.99)
            #expect(s.pixel(x: 22, y: 20)[3] == 0, "clipped")
            #expect(s.pixel(x: 2, y: 2)[3] == 0)
        }
    }

    /// The Metal rasterisation gives the CPU's paint bit for bit (every primitive kind, blend and
    /// renderer, at negative coordinates and across tile and bin edges).
    @Test func rasterParity() throws {
        guard AlgoGPU.isAvailable else { return }
        let c = PixelRect(x0: -37, y0: -21, x1: 363, y1: 279)
        var sets: [(String, [RenderProc.Prim])] = []
        for t in FlameType.allCases {
            var s = FlameSpec()
            s.flameType = t
            s.flameStyle = .violent
            sets.append(("flame \(t)", RPFix.flamePrims(s, c)))
        }
        for k: UInt32 in [1, 3, 4, 6, 7, 8, 14, 31] {
            var s = TreeSpec()
            s.baseTreeType = k
            sets.append(("tree \(k)", RenderProc.tree(s, canvas: c)))
        }
        for k in 1...UInt32(16) {
            var s = FrameSpec()
            s.frame = k
            s.fade = 40
            sets.append(("frame \(k)", RenderProc.pictureFrame(s, canvas: c)))
        }
        var worst: Float = 0
        for (name, prims) in sets {
            let used = prims.map(\.bounds).reduce(PixelRect.empty) { $1.isEmpty ? $0 : $0.union($1) }.intersect(c)
            let gpu = try RenderProcKit.rasterGPU(prims, used: used, clip: c).tile(used)
            let all = [UInt32](0..<UInt32(prims.count))
            let cpu = RenderProcKit.rasterTile(prims, all, used)
            var err: Float = 0
            for i in cpu.indices { err = max(err, (cpu[i] - gpu[i]).max(), (gpu[i] - cpu[i]).max()) }
            #expect(err == 0, "\(name): GPU paint differs by \(err)")
            worst = max(worst, err)
        }
        ParityLog.record("RenderProc.raster", worst)
    }

    /// Whole composites agree between backends on every model and depth, with a soft selection.
    @Test func compositeParityAcrossModels() throws {
        guard AlgoGPU.isAvailable else { return }
        let rect = PixelRect(x: 0, y: 0, width: 160, height: 120)
        var tree = TreeSpec()
        tree.baseTreeType = 7
        var frame = FrameSpec()
        frame.frame = 4
        let prims = RPFix.flamePrims(FlameSpec(), rect) + RenderProc.tree(tree, canvas: rect) + RenderProc.pictureFrame(frame, canvas: rect)
        var sel = Surface(format: .gray8)
        sel.writeRegion(rect, (0..<rect.area).map { Float($0 % 13) / 12 })
        for (mode, sample, alpha) in [(ColorMode.rgb, SampleType.u8, true), (.rgb, .f32, true), (.rgb, .u16, false), (.grayscale, .u8, true),
                                      (.cmyk, .u8, true), (.lab, .f32, true)] {
            let n = PixelFormat(mode: mode, sample: sample, alpha: alpha).channels
            let base = RPFix.surface(mode, sample, alpha: alpha, rect: rect, fill: (0..<n).map { Float($0 + 1) / Float(n + 2) })
            for selection in [nil, sel] {
                var a = base, b = base
                let ua = try RenderProc.composite(&a, prims, clip: rect, selection: selection, on: .cpu)
                let ub = try RenderProc.composite(&b, prims, clip: rect, selection: selection, on: .gpu)
                #expect(ua == ub)
                #expect(a.readRegion(rect) == b.readRegion(rect), "\(mode) \(sample) alpha \(alpha) selection \(selection != nil)")
            }
        }
    }

    // MARK: photocraft-engine render_cmds tests

    /// `each_renderer_draws_undoes_and_is_seeded_at_every_depth` (undo is the engine's).
    @Test func eachRendererDrawsAndIsSeededAtEveryDepth() throws {
        let rect = PixelRect(x: 0, y: 0, width: 160, height: 120)
        func prims(_ which: Int, seed: UInt32) -> [RenderProc.Prim] {
            switch which {
            case 0:
                var s = FlameSpec(); s.seed = seed
                return RPFix.flamePrims(s, rect)
            case 1:
                var s = TreeSpec(); s.baseTreeType = 7; s.seed = seed
                return RenderProc.tree(s, canvas: rect)
            default:
                var s = FrameSpec(); s.frame = 4; s.seed = seed
                return RenderProc.pictureFrame(s, canvas: rect)
            }
        }
        for sample in [SampleType.u8, .u16, .f32] {
            for which in 0..<3 {
                for be in RPFix.backends {
                    let p = prims(which, seed: 0)
                    #expect(!p.isEmpty)
                    var s = RPFix.surface(.rgb, sample)
                    let used = try RenderProc.composite(&s, p, clip: rect, on: be)
                    #expect(!used.isEmpty)
                    #expect(RPFix.opaque(s, rect) > 50, "\(which) @\(sample) drew \(RPFix.opaque(s, rect)) px")
                    var again = RPFix.surface(.rgb, sample)
                    try RenderProc.composite(&again, prims(which, seed: 0), clip: rect, on: be)
                    #expect(again.readRegion(rect) == s.readRegion(rect), "deterministic")
                    var other = RPFix.surface(.rgb, sample)
                    try RenderProc.composite(&other, prims(which, seed: 5), clip: rect, on: be)
                    #expect(other.readRegion(rect) != s.readRegion(rect), "seed changes the result")
                }
            }
        }
    }

    /// `flame_follows_the_work_path`.
    @Test func flameFollowsThePath() throws {
        var spec = FlameSpec()
        spec.width = 16
        spec.length = 60
        let prims = RenderProc.flame(spec, paths: [[SIMD2(20, 110), SIMD2(20, 20)]])
        var s = RPFix.surface()
        let b = try RenderProc.composite(&s, prims, clip: PixelRect(x: 0, y: 0, width: 160, height: 120))
        #expect(b.x0 < 20 && b.x1 < 60, "flame bounds \(b) hug the path at x = 20")
    }

    /// `selection_limits_and_new_layer`: the engine clips to the selection's bounds and mixes by it.
    @Test func selectionLimits() throws {
        let rect = PixelRect(x: 0, y: 0, width: 160, height: 120)
        var sel = Surface(format: .gray8)
        sel.writeRegion(PixelRect(x: 0, y: 0, width: 80, height: 120), [Float](repeating: 1, count: 80 * 120))
        var spec = TreeSpec()
        spec.leavesAmount = 100
        for be in RPFix.backends {
            var s = RPFix.surface()
            try RenderProc.composite(&s, RenderProc.tree(spec, canvas: rect), clip: rect.intersect(sel.contentBounds), selection: sel, on: be)
            let px = s.readRegion(rect)
            let right = (0..<rect.area).filter { $0 % 160 >= 81 && px[$0 * 4 + 3] > 0 }.count
            #expect(right == 0, "nothing drawn outside the selection")
            #expect(RPFix.opaque(s, rect) > 50)
        }
    }

    /// `works_in_cmyk_and_gray` (and Lab).
    @Test func worksInCMYKGrayAndLab() throws {
        let rect = PixelRect(x: 0, y: 0, width: 96, height: 96)
        var spec = FrameSpec()
        spec.frame = 13
        for mode in [ColorMode.cmyk, .grayscale, .lab] {
            for be in RPFix.backends {
                var s = RPFix.surface(mode, .u8, rect: rect)
                let used = try RenderProc.composite(&s, RenderProc.pictureFrame(spec, canvas: rect), clip: rect, on: be)
                #expect(!used.isEmpty, "\(mode)")
                #expect(RPFix.opaque(s, rect) > 50)
            }
        }
    }
}
