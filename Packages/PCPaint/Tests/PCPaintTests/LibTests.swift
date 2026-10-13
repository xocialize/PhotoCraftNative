// Port of photocraft-paint (crates/paint/src/lib.rs, rng.rs, tile.rs, procedural.rs, symmetry.rs, outline.rs, presets.rs tests), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import Testing
import PCFoundation
@testable import PCPaint

func stroke(_ points: [(Double, Double)], _ size: Float) -> Stroke {
    var b = BrushSettings()
    b.size = size
    b.pressureSize = false
    return Stroke(brush: b, points: points.map { StrokePoint($0.0, $0.1, 1) })
}

@Suite struct LibTests {
    @Test func dabSpacing() {
        let s = stroke([(0, 0), (100, 0)], 10)
        let d = dabs(s)
        // spacing 0.1 × 10 px = 1 px → ~101 dabs
        #expect((95...105).contains(d.count), "\(d.count)")
        var s2 = s
        s2.brush.spacing = 1
        #expect(dabs(s2).count == 11)
    }

    @Test func coverageProfile() {
        #expect(dabCoverage(0, 10, 1) == 1)
        #expect(dabCoverage(20, 10, 1) == 0)
        let softMid = dabCoverage(5, 10, 0)
        #expect(softMid > 0.2 && softMid < 0.8)
        #expect(dabCoverage(9.9, 10, 1) > 0.5)
    }

    @Test func hardBrushPaintsSolidLine() {
        var s = Surface(format: .rgba8)
        let dmg = applyStroke(&s, stroke([(10, 10), (90, 10)], 8))
        #expect(dmg.contains(x: 50, y: 10))
        #expect(s.pixel(x: 50, y: 10) == [0, 0, 0, 1])
        #expect(s.pixel(x: 50, y: 30)[3] == 0)
    }

    @Test func opacityCapsOverlap() {
        var s = Surface(format: .rgba8)
        var st = stroke([(10, 10), (60, 10), (10, 10)], 10)
        st.brush.opacity = 0.5
        applyStroke(&s, st)
        let a = s.pixel(x: 30, y: 10)[3]
        #expect(abs(a - 0.5) < 0.02, "\(a)")
    }

    @Test func selectionLimitsPaint() {
        var s = Surface(format: .rgba8)
        var sel = Surface(format: .gray8)
        sel.fillRect(PixelRect(x0: 0, y0: 0, x1: 50, y1: 100), [1])
        applyStroke(&s, stroke([(10, 10), (90, 10)], 8), selection: sel)
        #expect(s.pixel(x: 20, y: 10)[3] == 1)
        #expect(s.pixel(x: 70, y: 10)[3] == 0)
    }

    @Test func eraserRemovesAlpha() {
        var s = Surface(format: .rgba8)
        s.fillRect(PixelRect(x0: 0, y0: 0, x1: 100, y1: 20), [1, 0, 0, 1])
        var st = stroke([(10, 10), (90, 10)], 8)
        st.brush.erase = true
        applyStroke(&s, st)
        #expect(s.pixel(x: 50, y: 10)[3] == 0)
        #expect(s.pixel(x: 50, y: 1)[3] == 1)
    }

    @Test func lockTransparencyPreservesAlpha() {
        var s = Surface(format: .rgba8)
        s.fillRect(PixelRect(x0: 0, y0: 0, x1: 50, y1: 20), [1, 1, 1, 1])
        applyStroke(&s, stroke([(10, 10), (90, 10)], 8), lockTransparency: true)
        #expect(s.pixel(x: 20, y: 10) == [0, 0, 0, 1])
        #expect(s.pixel(x: 70, y: 10)[3] == 0)
    }

    @Test func pressureChangesSize() {
        var st = stroke([(0, 0), (100, 0)], 20)
        st.brush.pressureSize = true
        st.points[0].pressure = 0.1
        st.points[1].pressure = 1
        let d = dabs(st)
        #expect(d.first!.radius < d.last!.radius)
    }

    @Test func smoothingKeepsEndpoints() {
        let pts = (0..<20).map { StrokePoint(Double($0), $0 % 2 == 0 ? 0 : 10, 1) }
        let s = smooth(pts, amount: 0.8)
        #expect(s.first == pts.first)
        #expect(s.last == pts.last)
        let jitter = s[1..<19].map { abs($0.y - 5) }.reduce(0, +)
        let orig = pts[1..<19].map { abs($0.y - 5) }.reduce(0, +)
        #expect(jitter < orig)
    }

    @Test func worksAtAllDepths() {
        for f in [PixelFormat.rgba8, .rgba16, .rgba32f, .graya8, .cmyka8] {
            var s = Surface(format: f)
            var st = stroke([(5, 5), (40, 5)], 6)
            st.brush.color = SIMD4(1, 1, 1, 1)
            applyStroke(&s, st)
            let c = s.rgba(20, 5)
            #expect(c.w > 0.99 && c.x > 0.98, "\(f) \(c)")
        }
    }
}

@Suite struct RNGTests {
    @Test func deterministicAndUniformish() {
        #expect(PaintRNG.rand01(7, 3, 1) == PaintRNG.rand01(7, 3, 1))
        #expect(PaintRNG.rand01(7, 3, 1) != PaintRNG.rand01(8, 3, 1))
        #expect(PaintRNG.rand01(7, 3, 1) != PaintRNG.rand01(7, 3, 2))
        let n: UInt64 = 10000
        let mean = (0..<n).map { PaintRNG.rand01(1, $0, 0) }.reduce(0, +) / Float(n)
        #expect(abs(mean - 0.5) < 0.02, "\(mean)")
        #expect((0..<n).allSatisfy { (0..<1).contains(PaintRNG.rand01(2, $0, 5)) })
    }

    @Test func knownSplitMixValues() {
        // SplitMix64 reference outputs (seed 0 → first value of the canonical generator).
        #expect(PaintRNG.mix64(0) == 0xE220_A839_7B1D_CDAF)
        #expect(PaintRNG.seed(fromBytes: [UInt8]()) == PaintRNG.mix64(0xCBF2_9CE4_8422_2325))
    }
}

@Suite struct TileTests {
    @Test func base64RoundTrip() {
        for n in 0..<10 {
            let b = (0..<n).map { UInt8(truncatingIfNeeded: $0 * 37 + 5) }
            #expect(Base64.decode(Base64.encode(b)) == b)
        }
        #expect(Base64.encode(Array("Man".utf8)) == "TWFu")
        #expect(Base64.decode("TW E=\n") == Array("Ma".utf8))
        #expect(Base64.decode("TWE") == nil)
    }

    @Test func tileCodableRoundTripAndFloatForm() throws {
        let t = GrayTile(width: 5, height: 3) { x, y in Float(x + y) / 6 }
        let j = try JSONEncoder().encode(t)
        let back = try JSONDecoder().decode(GrayTile.self, from: j)
        #expect(back == t)
        let f = try JSONDecoder().decode(GrayTile.self, from: Data(#"{"width":2,"height":1,"data":[0.0,1.0]}"#.utf8))
        #expect(f.data == [0, 65535])
        #expect(throws: (any Error).self) { try JSONDecoder().decode(GrayTile.self, from: Data(#"{"width":2,"height":2,"data":[0.0,1.0]}"#.utf8)) }
    }

    @Test func previewDownscalesDeterministicallyAndToleratesBadTiles() {
        let t = GrayTile(width: 1000, height: 400) { x, _ in x < 500 ? 1 : 0 }
        let p = t.preview(96)
        #expect(p.isValid && p.width <= 96 && p.height <= 96, "\(p.width)×\(p.height)")
        #expect(p == t.preview(96))
        #expect(p.get(0, 0) > 0.99 && p.get(p.width - 1, 0) < 0.01)
        #expect(p.data.allSatisfy { $0 % 257 == 0 }, "8-bit levels")
        #expect(GrayTile(width: 5, height: 3) { _, _ in 0.5 }.preview(96).width == 5)
        #expect(GrayTile(width: 4, height: 4, data: [1]).preview(96).isValid)
        #expect(GrayTile(width: 0, height: 0, data: []).preview(0).isValid)
    }

    @Test func storedTilesCompareByKeyAndEncodeLoadedAsSampled() throws {
        let full = GrayTile(width: 300, height: 200) { x, y in Float((x + y) % 7) / 7 }
        let r = StoredTile(key: "abc", width: 300, height: 200, preview: full.preview(previewSide))
        var loaded = r
        loaded.full = full
        #expect(TipShape.stored(r) == TipShape.stored(loaded))
        #expect(TipShape.stored(r) != TipShape.sampled(full))
        #expect(r.bitmap.width == r.preview.width)
        #expect(loaded.bitmap == full)
        // Unloaded: a small reference that reads back as one.
        let j = try JSONEncoder().encode(TipShape.stored(r))
        let obj = try JSONSerialization.jsonObject(with: j) as! [String: Any]
        let stored = obj["stored"] as! [String: Any]
        #expect(stored["key"] as? String == "abc")
        #expect(stored["full"] == nil)
        #expect(try JSONDecoder().decode(TipShape.self, from: j) == TipShape.stored(r))
        // Loaded: the same JSON as an embedded bitmap.
        let enc = JSONEncoder()
        enc.outputFormatting = .sortedKeys
        #expect(try enc.encode(TipShape.stored(loaded)) == enc.encode(TipShape.sampled(full)))
        #expect(try enc.encode(Pattern.stored(loaded)) == enc.encode(Pattern.tile(full)))
        let pj = try JSONSerialization.jsonObject(with: enc.encode(Pattern.stored(r))) as! [String: Any]
        #expect((pj["stored"] as! [String: Any])["width"] as? Int == 300)
    }

    @Test func mipsAverage() {
        let t = GrayTile(width: 4, height: 4) { x, _ in x < 2 ? 1 : 0 }
        let m = Mips(t)
        #expect(m.levels.count == 3)
        #expect(abs(m.levels[2].v[0] - 0.5) < 1e-3)
        #expect(m.levelFor(4) == 0)
        #expect(m.levelFor(1) == 2)
    }
}

@Suite struct ProceduralTests {
    @Test func patternsAreSeamlessAndInRange() {
        for st in PatternStyle.allCases {
            let p = Procedural.pattern(st, 64, 3)
            #expect(p.data.allSatisfy { (0...1).contains($0) }, "\(st)")
            let v = p.data.map { abs($0 - 0.5) }.reduce(0, +) / Float(p.data.count)
            #expect(v > 0.02, "\(st) is flat")
            #expect(p.data == Procedural.pattern(st, 64, 3).data)
        }
        // Noise tiles: left and right columns are neighbours.
        let p = Procedural.pattern(.noise, 64, 1)
        let seam = (0..<64).map { abs(p.data[$0 * 64] - p.data[$0 * 64 + 63]) }.reduce(0, +) / 64
        #expect(seam < 0.08, "\(seam)")
    }

    @Test func tipsHavePaint() {
        for t in [Procedural.chalkTip(48, 1), Procedural.spatterTip(48, 1, 12), Procedural.bristleTip(48, 1), Procedural.charcoalTip(48, 1),
                  Procedural.leafTip(48), Procedural.grassTip(48, 1, 9), Procedural.spongeTip(48, 1), Procedural.starTip(48),
                  Procedural.rakeTip(48, 1, 7)] {
            #expect(t.isValid)
            let sum = t.toF32().reduce(0, +)
            #expect(sum > 48, "\(sum)")
            #expect(t.get(0, 0) == 0)
        }
    }
}

@Suite struct SymmetryTests {
    @Test func modesReflectAboutTheirCentreAndKeepStylusData() {
        var p = StrokePoint(12, 25, 0.4)
        p.tiltX = 18
        for (mode, expected) in [(SymmetryMode.vertical, SIMD2(28.0, 25.0)), (.horizontal, SIMD2(12.0, 35.0)), (.diagonal, SIMD2(15.0, 22.0))] {
            let s = PresetSymmetry(mode, center: SIMD2(20, 30), rotation: 0)!
            let r = s.reflectedPasses([p])[0][0]
            #expect(abs(r.x - expected.x) < 1e-9 && abs(r.y - expected.y) < 1e-9)
            #expect(r.pressure == p.pressure && r.tiltX == p.tiltX)
        }
        let s = PresetSymmetry(.dual, center: SIMD2(20, 30), rotation: 0)!
        let copies = s.reflectedPasses([p])
        #expect(copies.count == 3)
        for (c, e) in zip(copies, [SIMD2(28.0, 25.0), SIMD2(12.0, 35.0), SIMD2(28.0, 35.0)]) {
            #expect(abs(c[0].x - e.x) < 1e-9 && abs(c[0].y - e.y) < 1e-9)
        }
    }

    @Test func rotatedAxesClipOnRectanglesAndAcceptHalfPixelCentres() {
        for size in [SIMD2(100.0, 100.0), SIMD2(101.0, 53.0)] {
            for mode in SymmetryMode.allCases {
                let s = PresetSymmetry(mode, center: size / 2, rotation: 0)!
                let segments = s.segments(size)
                #expect(segments.count == (mode == .dual ? 2 : 1))
                for (a, b) in segments {
                    for p in [a, b] {
                        #expect(p.x >= -1e-9 && p.x <= size.x + 1e-9 && p.y >= -1e-9 && p.y <= size.y + 1e-9)
                    }
                }
                if mode == .diagonal {
                    let d = s.directions[0]
                    #expect(abs(d.x - d.y) < 1e-9)
                }
            }
        }
        let s = PresetSymmetry(.vertical, center: SIMD2(20, 30), rotation: 90)!
        let p = s.reflectedPasses([StrokePoint(12, 25, 1)])[0][0]
        #expect(abs(p.x - 12) < 1e-9 && abs(p.y - 35) < 1e-9)
        #expect(PresetSymmetry(.dual, center: SIMD2(.nan, 0), rotation: 0) == nil)
        #expect(PresetSymmetry(.dual, center: SIMD2(0, 0), rotation: .infinity) == nil)
        #expect(PresetSymmetry(.dual, center: SIMD2(symmetryMaxCoordinate + 1, 0), rotation: 0) == nil)
        #expect(PresetSymmetry(.horizontal, center: SIMD2(20, -5), rotation: 0)!.segments(SIMD2(100, 60)).isEmpty)
    }
}

@Suite struct OutlineTests {
    func maxRadius(_ rings: [[SIMD2<Float>]]) -> Float {
        rings.flatMap { $0 }.reduce(0) { max($0, hypotf($1.x, $1.y)) }
    }

    @Test func roundOutlinesSitOnTheHalfCoverageContour() {
        for hardness: Float in [0, 0.25, 0.5, 0.75, 1] {
            let b = with(BrushSettings()) { $0.size = 40; $0.angle = 33; $0.roundness = 0.4; $0.hardness = hardness }
            let normal = BrushOutline.tipOutline(b, full: false)!
            let full = BrushOutline.tipOutline(b, full: true)!
            #expect(abs(maxRadius(normal) - halfCoverageRadius(1, hardness)) < 1e-4, "hardness \(hardness)")
            #expect(abs(maxRadius(full) - 1) < 1e-4, "hardness \(hardness)")
        }
    }

    @Test func sampledOutlinesStayInsideTheTipAndBlankTipsHaveNone() {
        let disc = GrayTile(width: 32, height: 32) { x, y in
            let dx = Float(x) - 15.5, dy = Float(y) - 15.5
            return min(max(1 - (dx * dx + dy * dy).squareRoot() / 16, 0), 1)
        }
        let b = with(BrushSettings()) { $0.size = 20; $0.tip = .sampled(disc) }
        let rings = BrushOutline.tipOutline(b, full: false)!
        #expect(rings.allSatisfy { $0.count >= 3 })
        #expect(rings.flatMap { $0 }.allSatisfy { $0.x.isFinite && $0.y.isFinite && hypotf($0.x, $0.y) <= 1.001 })
        let blank = GrayTile(width: 8, height: 8) { _, _ in 0 }
        #expect(BrushOutline.tipOutline(with(BrushSettings()) { $0.size = 20; $0.tip = .sampled(blank) }, full: false) == nil)
        // And as a path for the cursor overlay.
        let path = BrushOutline.tipOutlinePath(b, full: false, center: CGPoint(x: 100, y: 50))!
        #expect(path.boundingBox.midX > 90 && path.boundingBox.midX < 110 && path.boundingBox.width <= 20.1)
    }

    @Test func hostileSettingsGetNoOutline() {
        for size: Float in [.nan, .infinity, 0, -1] {
            #expect(BrushOutline.tipOutline(with(BrushSettings()) { $0.size = size; $0.angle = 33; $0.roundness = 0.5 }, full: false) == nil, "size \(size)")
        }
        for angle: Float in [.nan, .infinity] {
            #expect(BrushOutline.tipOutline(with(BrushSettings()) { $0.size = 40; $0.angle = angle; $0.roundness = 0.5 }, full: false) == nil)
        }
    }
}

@Suite struct PresetTests {
    @Test func builtinsAreGroupedAndUnique() {
        let v = BrushPresets.builtin()
        #expect((30...40).contains(v.count), "\(v.count)")
        #expect(Set(v.map(\.name)).count == v.count, "duplicate preset names")
        for g in BrushPresets.groups { #expect(v.filter { $0.group == g }.count >= 6, "\(g)") }
        #expect(v.allSatisfy { $0.builtin && BrushPresets.groups.contains($0.group) })
        let order = v.compactMap { p in BrushPresets.groups.firstIndex(of: p.group) }
        #expect(zip(order, order.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(BrushPresets.find(v, "Hard Round Pressure Size")?.brush.shapeDynamics.size.control == .penPressure)
    }
}
