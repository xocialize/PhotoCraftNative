// Port of photocraft-engine (crates/engine/src/retouch_cmds/tests.rs, retouch_cmds/pattern_stamp.rs `mod tests`) and of the photocraft-algo kernel tests (crates/algo/src/poisson.rs, crates/algo/src/retouch.rs `mod tests`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Skipped (another module's commands, or API not ported here): `remove_*` (Remove is the
// PCIntelligence glue's), `live_clone_matches_the_commit`, `live_dodge_matches_the_commit_across_cells`
// and the `live_coordinate_regression!` tests (the engine's LiveRetouch/LiveDab preview objects are
// not ported; PCPaint has its own LiveRetouch). Setups photocraft builds with `paint.stroke`,
// `edit.fill`, `layer.lockLayers`, `channel.new` and `select.editInQuickMaskMode` (other modules)
// are made with direct edits; Pattern Stamp tests install a test pattern library with photocraft's
// built-in Checkerboard and Bricks (pattern_cmds is another module).

import Foundation
import PCDocument
@testable import PCEngine
import PCFoundation
import PCPaint
import PCRender
import Testing

@Suite struct RetouchTests {
    static let depths = [8, 16, 32]

    func session(_ w: Int, _ h: Int, _ depth: Int, _ mode: String) throws -> Session {
        RetouchTests.installPatternLibrary()
        let s = Session()
        try s.execute("file.new", ["width": .int(w), "height": .int(h), "depth": .int(depth), "mode": .string(mode)])
        return s
    }

    /// Straight RGBA of the active layer at a pixel.
    func rgba(_ s: Session, _ x: Int32, _ y: Int32) -> SIMD4<Float> {
        guard let d = s.active, let id = d.activeLayer, let surf = d.doc.layer(id)?.surface else { return SIMD4(-1, -1, -1, -1) }
        return surf.rgba(x: x, y: y)
    }

    func paintLayer(_ s: Session, _ f: (Int32, Int32) -> SIMD4<Float>) throws {
        try s.edit("setup") { doc, active in
            let b = doc.bounds
            _ = doc.withRaster(of: active!) { surf in
                let fmt = surf.format
                var data: [Float] = []
                data.reserveCapacity(b.area * fmt.channels)
                for y in b.y0..<b.y1 { for x in b.x0..<b.x1 { data += fromRGBA(fmt, f(x, y)) } }
                surf.writeRegion(b, data)
            }
        }
    }

    func tol(_ depth: Int) -> Float { depth == 8 ? 1 / 255 + 1e-4 : 1e-3 }

    /// A smooth colour gradient plus deterministic fine noise.
    static func texture(_ x: Int32, _ y: Int32) -> SIMD4<Float> {
        let n = Float(UInt32(bitPattern: (x &* 73_856_093) ^ (y &* 19_349_663)) % 1000) / 1000 * 0.06 - 0.03
        return SIMD4(0.3 + 0.004 * Float(x) + n, 0.5 + 0.003 * Float(y) + n, 0.45 + n, 1)
    }

    func layerSurface(_ s: Session) -> Surface? { s.active.flatMap { d in d.activeLayer.flatMap { d.doc.layer($0)?.surface } } }

    func isBadParams(_ e: any Error) -> Bool {
        if case .badParams? = e as? EngineError { return true }
        return false
    }

    // MARK: Test pattern library (photocraft pattern_cmds::builtin)

    static func hash01(_ x: UInt32, _ y: UInt32, _ seed: UInt32) -> Float {
        var h = (x &* 0x8da6_b343) ^ (y &* 0xd816_3841) ^ (seed &* 0xcb1a_b31f)
        h ^= h >> 13
        h = h &* 0x5bd1_e995
        h ^= h >> 15
        return Float(h & 0xffff) / 65535
    }

    static func procedural(_ name: String, _ w: UInt32, _ h: UInt32, _ f: (UInt32, UInt32) -> SIMD3<Float>) -> PCDocument.Pattern {
        var s = Surface(format: PixelFormat(mode: .rgb, sample: .u8, alpha: false))
        var px: [Float] = []
        for y in 0..<h { for x in 0..<w { let c = f(x, y); px += [c.x, c.y, c.z] } }
        s.writeRegion(PixelRect(x0: 0, y0: 0, x1: Int32(w), y1: Int32(h)), px)
        return PCDocument.Pattern(name: name, surface: s, width: w, height: h)
    }

    static let library: [PCDocument.Pattern] = [
        procedural("Checkerboard", 16, 16) { x, y in SIMD3(repeating: (x / 8 + y / 8) % 2 == 0 ? 0.8 : 1) },
        procedural("Bricks", 32, 16) { x, y in
            let row = y / 8
            let xo = (x + (row % 2 == 1 ? 8 : 0)) % 16
            let mortar = y % 8 == 7 || xo == 15
            let n = hash01(x, y, 7) * 0.08
            return mortar ? SIMD3(0.78 + n, 0.76 + n, 0.72 + n) : SIMD3(0.62 + n, 0.27 + n * 0.5, 0.2)
        },
        PCDocument.Pattern(id: "empty-pat", name: "EmptyTile", width: 0, height: 0, surface: Surface(format: PixelFormat(mode: .rgb, sample: .u8, alpha: false))),
    ]

    /// Stands in for the Patterns panel's library (process-wide; no other suite paints from it).
    static func installPatternLibrary() {
        RetouchCommands.installPatternLibrary(replace: false) { _ in .init(current: nil, items: RetouchTests.library) }
    }

    // MARK: Clone Stamp

    @Test func clonePreviewMatchesSourceWithoutMutatingSession() throws {
        for depth in Self.depths {
            let s = try session(32, 32, depth, "rgb")
            try paintLayer(s) { x, y in SIMD4(Float(x) / 32, Float(y) / 32, 0.25, 1) }
            try s.execute("cloneSource.set", ["source": [8, 8]])
            let revision = s.active!.revision
            let slots = s.state[CloneSourceCommands.SourcesKey.self]
            let map = CloneMapping(source: SIMD2(8, 8), anchor: SIMD2(20, 20))
            let buf = try RetouchCommands.clonePreview(s, rect: PixelRect(x0: 20, y0: 20, x1: 21, y1: 21), map: map, sampleLayer: "current")
            let expected = rgba(s, 8, 8)
            for c in 0..<4 { #expect(abs(buf.px[0][c] - expected[c]) < 0.001) }
            #expect(s.active!.revision == revision)
            #expect(s.state[CloneSourceCommands.SourcesKey.self] == slots)
            #expect(throws: EngineError.self) { try RetouchCommands.clonePreview(s, rect: PixelRect(x0: 0, y0: 0, x1: 2048, y1: 2048), map: map, sampleLayer: "current") }
            #expect(throws: EngineError.self) { try RetouchCommands.clonePreview(s, rect: PixelRect(x0: 20, y0: 20, x1: 21, y1: 21), map: map, sampleLayer: "invalid") }
            var invalid = map
            invalid.source.x = .nan
            #expect(throws: EngineError.self) { try RetouchCommands.clonePreview(s, rect: PixelRect(x0: 0, y0: 0, x1: 1, y1: 1), map: invalid, sampleLayer: "current") }
        }
    }

    @Test func cloneStampCopiesExactlyAtAllDepths() throws {
        for depth in Self.depths {
            let s = try session(96, 64, depth, "rgb")
            try paintLayer(s) { x, y in SIMD4(Float(x) / 96, Float(y) / 64, Float((x * 7 + y * 3) % 11) / 11, 1) }
            let r = try s.execute("paint.cloneStamp", ["points": [[60, 30], [80, 30]], "source": [20, 20], "size": 10, "hardness": 100])
            #expect(r["offset"] == [-40, -10])
            #expect(r["nextSource"] == .null, "aligned keeps the offset")
            for x: Int32 in [60, 70, 80] {
                let (got, want) = (rgba(s, x, 30), rgba(s, x - 40, 20))
                for c in 0..<4 { #expect(abs(got[c] - want[c]) <= tol(depth), "depth \(depth) x \(x): \(got) vs \(want)") }
            }
            // Outside the brush untouched.
            let far = rgba(s, 70, 50)
            #expect(abs(far.x - 70 / 96) <= tol(depth) && abs(far.y - 50 / 64) <= tol(depth))
            // One undo step.
            #expect(s.undo())
            #expect(abs(rgba(s, 70, 30).y - 30 / 64) <= tol(depth))
        }
    }

    @Test func retouchRejectsBrushesLargerThanTheRasterBudget() throws {
        let s = try session(32, 32, 8, "rgb")
        #expect(throws: EngineError.self) { try s.execute("paint.dodge", ["points": [[10, 10]], "size": 1e30]) }
    }

    @Test func cloneStampSamplesPreStrokeStateAndNonAlignedReturnsSource() throws {
        let s = try session(80, 20, 16, "rgb")
        try paintLayer(s) { x, _ in SIMD4(Float(x) / 80, 0, 0, 1) }
        // Source 4 px to the right of the stroke start, stroke runs right: without pre-stroke
        // sampling the stroke would re-clone its own output and smear.
        let r = try s.execute("paint.cloneStamp", ["points": [[10, 10], [50, 10]], "source": [14, 10], "size": 6, "hardness": 100, "aligned": false])
        #expect(r["nextSource"] == [14.0, 10.0])
        for x: Int32 in [20, 30, 45] { #expect(abs(rgba(s, x, 10).x - Float(x + 4) / 80) < 1e-3, "x \(x)") }
        #expect(throws: EngineError.self, "source is required") { try s.execute("paint.cloneStamp", ["points": [[1, 1]]]) }
        // An explicit offset works too.
        try s.execute("paint.cloneStamp", ["points": [[70, 10]], "offset": [-60, 0], "size": 4, "hardness": 100])
        #expect(abs(rgba(s, 70, 10).x - 14 / 80) < 1e-3, "samples the current state (x=10 was cloned from x=14)")
    }

    @Test func cloneStampSampleAllLayersOntoEmptyLayerAndOpacity() throws {
        let s = try session(64, 32, 8, "rgb")
        try paintLayer(s) { x, _ in x < 32 ? SIMD4(1, 0, 0, 1) : SIMD4(1, 1, 1, 1) }
        try s.execute("layer.new.layer")
        // Current layer is empty: sampling "current" clones transparency (a no-op) …
        try s.execute("paint.cloneStamp", ["points": [[48, 16]], "source": [16, 16], "size": 8, "hardness": 100])
        #expect(rgba(s, 48, 16).w == 0)
        // … sampling all layers clones the visible red.
        try s.execute("paint.cloneStamp", ["points": [[48, 16]], "source": [16, 16], "size": 8, "hardness": 100, "sampleLayer": "all"])
        let p = rgba(s, 48, 16)
        #expect(p.x > 0.99 && p.y < 0.01 && p.w > 0.99, "\(p)")
        // currentAndBelow on the bottom layer ignores layers above.
        try s.execute("paint.cloneStamp", ["points": [[40, 5]], "source": [8, 5], "size": 4, "hardness": 100, "opacity": 50, "sampleLayer": "currentAndBelow"])
        let q = rgba(s, 40, 5)
        #expect(abs(q.w - 0.5) < 0.02, "opacity 50 → half alpha \(q)")
        #expect(throws: EngineError.self) { try s.execute("paint.cloneStamp", ["points": [[1, 1]], "source": [0, 0], "sampleLayer": "nope"]) }
    }

    @Test func cloneStampRespectsSelectionAndCMYK() throws {
        let s = try session(64, 32, 8, "cmyk")
        try paintLayer(s) { x, _ in x < 32 ? SIMD4(0, 0, 1, 1) : SIMD4(1, 1, 0, 1) }
        try s.execute("select.rect", ["x": 40, "y": 0, "width": 8, "height": 32])
        try s.execute("paint.cloneStamp", ["points": [[36, 16], [56, 16]], "offset": [-30, 0], "size": 8, "hardness": 100])
        // CMYK pixels display through the CMYK profile: sRGB blue/yellow come back less saturated.
        let (inside, outside) = (rgba(s, 44, 16), rgba(s, 52, 16))
        #expect(inside.z > inside.x + 0.2, "inside the selection: cloned blue \(inside)")
        #expect(outside.z < 0.3 && outside.x > 0.8, "outside the selection: untouched yellow \(outside)")
    }

    @Test func healingBrushTakesDestinationColourAndSourceTexture() throws {
        for depth in [8, 32] {
            let s = try session(128, 64, depth, "rgb")
            // Left: dark blue with strong vertical stripes (the texture); right: flat light orange.
            try paintLayer(s) { x, _ in
                if x < 64 {
                    let t: Float = (x / 3) % 2 == 0 ? 0.08 : -0.08
                    return SIMD4(0.1 + t + 0.1, 0.15 + t + 0.1, 0.5 + t, 1)
                }
                return SIMD4(0.9, 0.6, 0.3, 1)
            }
            try s.execute("paint.healingBrush", ["points": [[96, 32]], "source": [32, 32], "size": 30, "hardness": 100])
            // Inside the healed disc: mean ≈ destination colour, variance ≈ source texture.
            var vals: [SIMD4<Float>] = []
            for dy: Int32 in -8...8 { for dx: Int32 in -8...8 { vals.append(rgba(s, 96 + dx, 32 + dy)) } }
            let mean = (0..<3).map { c in vals.reduce(0) { $0 + $1[c] } / Float(vals.count) }
            for (c, want) in [Float(0.9), 0.6, 0.3].enumerated() { #expect(abs(mean[c] - want) < 0.06, "depth \(depth) channel \(c): mean \(mean[c]) want \(want)") }
            let variance = vals.reduce(0) { $0 + ($1.y - mean[1]) * ($1.y - mean[1]) } / Float(vals.count)
            #expect(variance > 0.003, "texture carried: variance \(variance)")
            // Horizontal gradient pattern matches the source stripes (period 6).
            let a = rgba(s, 96, 32).y - rgba(s, 95, 32).y, b = rgba(s, 32, 32).y - rgba(s, 31, 32).y
            #expect(abs(a - b) < 0.03, "gradient \(a) vs source \(b)")
            #expect(abs(rgba(s, 125, 3).x - 0.9) <= tol(depth))
        }
    }

    @Test func cloneAndHealWithAFarSourceArePlainErrors() throws {
        // Issue #1111: an offset that saturates the rectangle translation is a bad-params error,
        // and the layer is untouched.
        for cmd in ["paint.cloneStamp", "paint.healingBrush"] {
            let s = try session(40, 30, 8, "rgb")
            try paintLayer(s, Self.texture)
            let before = rgba(s, 10, 10)
            let steps = s.active!.history.pastCount
            let cases: [JSONValue] = [
                ["points": [[10, 10]], "source": [3e9, 0]], ["points": [[10, 10]], "source": [0, -3e9]],
                ["points": [[10, 10]], "offset": [2_147_483_647, 0]], ["points": [[10, 10], [30, 10]], "source": [2_147_483_640, 0]],
            ]
            for p in cases {
                do {
                    try s.execute(cmd, p)
                    Issue.record("\(cmd) \(p) succeeded")
                } catch {
                    #expect(isBadParams(error), "\(cmd) \(p): \(error)")
                }
            }
            #expect(rgba(s, 10, 10) == before, "\(cmd): a refused stroke changed the layer")
            #expect(s.active!.history.pastCount == steps, "\(cmd): a refused stroke recorded a history step")
            // A source far outside the canvas but inside the coordinate range clones transparency.
            try s.execute(cmd, ["points": [[10, 10]], "source": [1e6, 1e6]])
            try s.execute(cmd, ["points": [[10, 10], [30, 10]], "source": [2_147_483_000, 0]])
        }
    }

    // MARK: Toning and focus

    @Test func dodgeBrightensMidtonesMoreThanShadowsAndBurnDarkens() throws {
        for depth in Self.depths {
            let s = try session(80, 20, depth, "rgb")
            try paintLayer(s) { x, _ in x < 40 ? SIMD4(0.5, 0.5, 0.5, 1) : SIMD4(0.08, 0.08, 0.08, 1) }
            try s.execute("paint.dodge", ["points": [[5, 10], [75, 10]], "size": 10, "hardness": 100])
            let (mid, shadow) = (rgba(s, 20, 10).x - 0.5, rgba(s, 60, 10).x - 0.08)
            #expect(mid > 0.05, "depth \(depth): midtone +\(mid)")
            #expect(mid > 2 * max(shadow, 0), "depth \(depth): midtone +\(mid) shadow +\(shadow)")
            try s.execute("paint.burn", ["points": [[5, 15], [35, 15]], "size": 6, "hardness": 100, "exposure": 80])
            #expect(rgba(s, 20, 15).x < 0.45)
            // Shadows range dodges the dark side more than the grey.
            try s.execute("paint.dodge", ["points": [[5, 3], [75, 3]], "size": 4, "hardness": 100, "range": "shadows"])
            #expect(rgba(s, 60, 3).x - 0.08 > rgba(s, 20, 3).x - 0.5)
        }
        // Grayscale document too.
        let s = try session(20, 20, 8, "gray")
        try s.execute("paint.burn", ["points": [[10, 10]], "size": 6, "hardness": 100, "range": "highlights"])
        #expect(rgba(s, 10, 10).x < 0.9)
        #expect(s.active!.doc.pixelFormat.mode == .grayscale)
    }

    @Test func dodgeDoesNotCompoundWithinAStroke() throws {
        // Going back over the same spot in one stroke tones it no further; a second stroke does.
        func once(_ pts: JSONValue) throws -> (Float, Session) {
            let s = try session(80, 20, 8, "rgb")
            try paintLayer(s) { _, _ in SIMD4(0.5, 0.5, 0.5, 1) }
            try s.execute("paint.dodge", ["points": pts, "size": 10, "hardness": 100])
            return (rgba(s, 40, 10).x, s)
        }
        let (single, s) = try once([[5, 10], [75, 10]])
        let (scrubbed, _) = try once([[5, 10], [75, 10], [5, 10], [75, 10]])
        #expect(single > 0.55 && abs(single - scrubbed) < 1 / 255, "\(single) \(scrubbed)")
        try s.execute("paint.dodge", ["points": [[5, 10], [75, 10]], "size": 10, "hardness": 100])
        #expect(rgba(s, 40, 10).x > single + 0.02)
    }

    @Test func spongeReducesAndIncreasesSaturation() throws {
        for depth in Self.depths {
            let s = try session(40, 20, depth, "rgb")
            try paintLayer(s) { _, _ in SIMD4(0.8, 0.4, 0.3, 1) }
            func sat(_ p: SIMD4<Float>) -> Float { RetouchCommands.Kernels.saturation(SIMD3(p.x, p.y, p.z)) }
            let s0 = sat(rgba(s, 10, 10))
            try s.execute("paint.sponge", ["points": [[2, 10], [38, 10]], "size": 8, "hardness": 100])
            let s1 = sat(rgba(s, 10, 10))
            #expect(s1 < s0 * 0.8, "depth \(depth): \(s0) → \(s1)")
            try s.execute("paint.sponge", ["points": [[2, 3], [38, 3]], "size": 4, "hardness": 100, "mode": "saturate", "vibrance": false])
            #expect(sat(rgba(s, 10, 3)) > s0)
        }
    }

    func variance(_ s: Session, _ x0: Int32) -> Float {
        var v: [Float] = []
        for y: Int32 in 10..<20 { for x in x0..<(x0 + 10) { v.append(rgba(s, x, y).x) } }
        let m = v.reduce(0, +) / Float(v.count)
        return v.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Float(v.count)
    }

    @Test func blurReducesLocalVarianceAndSharpenIncreasesIt() throws {
        for depth in [8, 16] {
            let s = try session(60, 30, depth, "rgb")
            try paintLayer(s) { x, y in (x + y) % 2 == 0 ? SIMD4(0.3, 0.3, 0.3, 1) : SIMD4(0.7, 0.7, 0.7, 1) }
            let v0 = variance(s, 10)
            try s.execute("paint.blur", ["points": [[5, 15], [25, 15]], "size": 20, "hardness": 100, "strength": 100])
            #expect(variance(s, 10) < v0 * 0.5, "depth \(depth): \(v0) → \(variance(s, 10))")
            #expect(abs(variance(s, 45) - v0) < 1e-3, "outside untouched")
            // Sharpen a low-contrast checkerboard: contrast grows; Protect Detail caps it at the local range.
            let t = try session(60, 30, depth, "rgb")
            try paintLayer(t) { x, y in (x + y) % 2 == 0 ? SIMD4(0.45, 0.45, 0.45, 1) : SIMD4(0.55, 0.55, 0.55, 1) }
            let w0 = variance(t, 10)
            try t.execute("paint.sharpen", ["points": [[5, 15], [25, 15]], "size": 20, "hardness": 100, "strength": 100, "protectDetail": false])
            #expect(variance(t, 10) > w0 * 1.5, "depth \(depth): \(w0) → \(variance(t, 10))")
            try t.execute("paint.sharpen", ["points": [[35, 15], [55, 15]], "size": 20, "hardness": 100, "strength": 100, "spacing": 25])
            var hi: Float = 0
            for y: Int32 in 10..<20 { for x: Int32 in 40..<50 { hi = max(hi, rgba(t, x, y).x) } }
            #expect(hi <= 0.55 + tol(depth), "protect detail: \(hi)")
        }
    }

    @Test func smudgeMovesColourAlongTheStroke() throws {
        for depth in Self.depths {
            let s = try session(100, 30, depth, "rgb")
            try paintLayer(s) { x, _ in x < 30 ? SIMD4(1, 0, 0, 1) : SIMD4(1, 1, 1, 1) }
            try s.execute("paint.smudge", ["points": [[20, 15], [70, 15]], "size": 12, "hardness": 100, "strength": 80])
            let g = { (x: Int32) in rgba(s, x, 15).y }
            #expect(g(36) < 0.6, "depth \(depth): red dragged right (\(g(36)))")
            #expect(g(36) < g(65))
            #expect(rgba(s, 36, 2).y > 0.99, "off-stroke untouched")
            try s.execute("tools.setColors", ["foreground": "#0000ff"])
            try s.execute("paint.smudge", ["points": [[80, 25], [95, 25]], "size": 6, "hardness": 100, "fingerPainting": true])
            #expect(rgba(s, 81, 25).x < 0.7, "finger painting lays down the foreground colour")
        }
    }

    @Test func smudgeUsesTheBrushSettingsSpacing() throws {
        // #2140: the Brush Settings spacing drives Smudge dabs when the stroke has no `spacing`.
        func run(_ spacing: Float, _ p: JSONValue) throws -> [Float] {
            let s = try session(100, 30, 8, "rgb")
            try paintLayer(s) { x, _ in x < 30 ? SIMD4(1, 0, 0, 1) : SIMD4(1, 1, 1, 1) }
            s.tools.brush.spacing = spacing
            try s.execute("paint.smudge", p.setting("points", [[20, 15], [90, 15]]))
            return (30..<95).map { rgba(s, Int32($0), 15).y }
        }
        let base: JSONValue = ["size": 12, "hardness": 100, "strength": 80]
        let dense = try run(0.01, base)
        let sparse = try run(10, base)
        // 1000% of 12 px puts the next dab 120 px away: only the first dab, behind the edge, lands.
        #expect(sparse.allSatisfy { $0 > 0.99 }, "1000% spacing: nothing dragged past the edge")
        #expect((dense.first ?? 1) < 0.6, "1% spacing: red dragged right (\(String(describing: dense.first)))")
        #expect(try dense != run(0.25, base), "1% and 25% differ")
        // An explicit `spacing` param still wins over the Brush Settings value.
        #expect(try run(0.01, base.setting("spacing", 1000)) == sparse)
    }

    // MARK: History Brush

    /// photocraft's `paint.stroke` setup as a direct edit: a band of `color` over rows 4…15.
    func band(_ s: Session, _ color: SIMD4<Float>) throws {
        try s.edit("Brush Tool") { doc, active in
            _ = doc.withRaster(of: active!) { surf in
                let r = PixelRect(x0: 0, y0: 4, x1: 40, y1: 16)
                surf.writeRGBA(r, [SIMD4<Float>](repeating: color, count: r.area))
            }
        }
    }

    func setPixelsLock(_ s: Session, _ on: Bool) throws {
        try s.edit("Lock") { doc, active in _ = doc.updateLayer(active!) { $0.locks.pixels = on } }
    }

    func fillRed(_ s: Session) throws {
        try s.edit("Fill") { doc, active in
            let b = doc.bounds
            _ = doc.withRaster(of: active!) { $0.writeRGBA(b, [SIMD4<Float>](repeating: SIMD4(1, 0, 0, 1), count: b.area)) }
        }
    }

    @Test func historyBrushRestoresEarlierPixels() throws {
        for depth in [8, 32] {
            let s = try session(40, 20, depth, "rgb")
            try band(s, SIMD4(1, 0, 0, 1))
            try band(s, SIMD4(0, 1, 0, 1))
            #expect(rgba(s, 20, 10).y > 0.99)
            // State 1 = after the red stroke.
            try s.execute("paint.historyBrush", ["points": [[5, 10], [15, 10]], "size": 6, "hardness": 100, "state": 1])
            let p = rgba(s, 10, 10)
            #expect(p.x > 0.99 && p.y < 0.01, "depth \(depth): \(p)")
            // Default = the Open snapshot: white.
            try s.execute("paint.historyBrush", ["points": [[25, 10], [35, 10]], "size": 6, "hardness": 100])
            let q = rgba(s, 30, 10)
            #expect(q.x > 0.99 && q.y > 0.99 && q.z > 0.99 && q.w > 0.99)
            #expect(rgba(s, 20, 10).y > 0.99, "between the dabs still green")
            #expect(throws: EngineError.self) { try s.execute("paint.historyBrush", ["points": [[5, 10]], "state": 99]) }
        }
    }

    @Test func historyBrushReadsASourceWhenItsPixelsWereLocked() throws {
        // A white layer locked in history state 1, then unlocked and filled red.
        let s = try session(16, 16, 8, "rgb")
        try setPixelsLock(s, true)
        try setPixelsLock(s, false)
        try fillRed(s)
        // History Brush samples the locked historical pixels: the historical lock limits edits, not reads.
        try s.execute("paint.historyBrush", ["points": [[8, 8]], "size": 4, "hardness": 100, "state": 1])
        let p = rgba(s, 8, 8)
        #expect(p.x > 0.99 && p.y > 0.99 && p.z > 0.99, "\(p)")
    }

    @Test func historyBrushRefusesALockedDestinationWhenSourceIsUnlocked() throws {
        let s = try session(16, 16, 8, "rgb")
        try fillRed(s)
        try setPixelsLock(s, true)
        #expect(throws: EngineError.self) { try s.execute("paint.historyBrush", ["points": [[8, 8]], "size": 4, "hardness": 100, "state": 0]) }
        let p = rgba(s, 8, 8)
        #expect(p.x > 0.99 && p.y < 0.01, "\(p)")
    }

    @Test func historyBrushErrorsWhenLayerIsNew() throws {
        let s = try session(20, 20, 8, "rgb")
        try s.execute("layer.new.layer")
        #expect(throws: EngineError.self) { try s.execute("paint.historyBrush", ["points": [[5, 5]], "state": 0]) }
    }

    // MARK: Registry and targets

    static let retouchIds = ["paint.cloneStamp", "paint.patternStamp", "paint.healingBrush", "paint.spotHealing", "paint.dodge", "paint.burn",
                             "paint.sponge", "paint.blur", "paint.sharpen", "paint.smudge", "paint.historyBrush"]
    /// The ones that run in this build (all of them, now that PCAlgo's inpainting is available).
    static let runnableIds = retouchIds

    @Test func retouchCommandsAreRegisteredAndNeedAPixelLayer() throws {
        Self.installPatternLibrary()
        let fresh = Session()
        for id in Self.retouchIds {
            let spec = try #require(fresh.registry.spec(id), "\(id) missing")
            #expect(spec.params.contains("\"points\"") && spec.params.contains("spacing"), "\(id)")
            #expect(!fresh.isEnabled(id))
        }
        let s = try session(10, 10, 8, "rgb")
        #expect(throws: EngineError.self) { try s.execute("paint.dodge", ["points": []]) }
        #expect(throws: EngineError.self) { try s.execute("paint.dodge", ["points": [[1, 1]], "range": "bogus"]) }
        #expect(throws: EngineError.self) { try s.execute("paint.spotHealing", ["points": [[1, 1]], "type": "bogus"]) }
        #expect(s.registry.spec("paint.spotHealing")?.isAvailable == true && s.registry.spec("paint.contentAwareMove")?.isAvailable == true)
        var own = CommandRegistry()
        own.install(RetouchCommands.self)
        #expect(!own.contains("paint.remove"), "Remove is the PCIntelligence glue's")
        #expect(own.count == 13)
    }

    /// Not a photocraft test: ids, labels, menus, shortcuts and params match photocraft's
    /// catalogue for every command these modules register.
    @Test func specsMatchThePhotocraftCatalogue() {
        let catalog = Dictionary(PhotocraftCatalog.commands.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for module in [RetouchCommands.self, CloneSourceCommands.self, RedEyeCommands.self, SwatchCommands.self] as [any CommandModule.Type] {
            var r = CommandRegistry()
            r.install(module)
            for spec in r.specs {
                guard let c = catalog[spec.id] else { Issue.record("\(spec.id) is not a photocraft command"); continue }
                #expect(spec.label == c.label && spec.menu == c.menu && spec.shortcut == c.shortcut && spec.module == c.module, "\(spec.id)")
                if !c.params.contains("(see photocraft source)") { #expect(spec.params == c.params, "\(spec.id)") }
            }
        }
    }

    static func grayNoise(_ x: Int32, _ y: Int32) -> Float { 0.3 + Float(((x * 7 + y * 13) % 10 + 10) % 10) * 0.04 }

    static func textureSurface(_ surf: inout Surface, _ b: PixelRect) {
        var data: [Float] = []
        for y in b.y0..<b.y1 { for x in b.x0..<b.x1 { data.append(grayNoise(x, y)) } }
        surf.writeRegion(b, data)
    }

    /// A textured pixel layer with a textured mask and a textured alpha channel. Returns the
    /// history index of the state before the mask and channel were textured.
    func targetedSession() throws -> (Session, Int) {
        let s = try session(60, 40, 8, "rgb")
        try s.execute("layer.new.layer")
        try paintLayer(s, Self.texture)
        try s.execute("layer.layerMask.revealAll")
        try s.edit("New Channel") { doc, _ in
            doc.channels.append(AlphaChannel(name: "Alpha 1", surface: Surface(format: Channels.channelFormat(doc), defaultPixel: [1])))
        }
        let before = s.active!.history.pastCount
        try s.edit("texture") { doc, active in
            let b = doc.bounds
            _ = doc.updateLayer(active!) { l in
                if var m = l.mask { Self.textureSurface(&m.surface, b); l.mask = m }
            }
            Self.textureSurface(&doc.channels[0].surface, b)
        }
        return (s, before)
    }

    func retouchParams(_ id: String, _ state: Int, _ target: JSONValue?) -> JSONValue {
        var p: JSONValue = ["points": [[20, 20], [40, 20]], "size": 12, "hardness": 100, "strength": 100, "exposure": 100]
        if let target { p = p.setting("target", target) }
        switch id {
        case "paint.cloneStamp", "paint.healingBrush": p = p.setting("offset", [-13, 3])
        case "paint.historyBrush": p = p.setting("state", .int(state))
        case "paint.sponge": p = p.setting("mode", "saturate")
        default: break
        }
        return p
    }

    /// Tools whose stroke must visibly change grey noise (Sponge has no colour to change on grey,
    /// healing a noise texture with itself may land on the same values).
    func changesGray(_ id: String) -> Bool { !["paint.sponge", "paint.healingBrush", "paint.spotHealing"].contains(id) }

    func read(_ surf: Surface?, _ b: PixelRect) -> [Float] { surf?.readRegion(b) ?? [] }
    func maskSurface(_ s: Session) -> Surface? { s.active.flatMap { d in d.activeLayer.flatMap { d.doc.layer($0)?.mask?.surface } } }
    func channelSurface(_ s: Session) -> Surface? { s.active?.doc.channels.first?.surface }

    @Test func retouchToolsPaintOnlyTheTargetedMask() throws {
        for id in Self.runnableIds {
            let (s, state) = try targetedSession()
            let b = s.active!.doc.bounds
            let (px0, mask0, ch0) = (read(layerSurface(s), b), read(maskSurface(s), b), read(channelSurface(s), b))
            try s.execute(id, retouchParams(id, state, "mask"))
            #expect(read(layerSurface(s), b) == px0, "\(id): layer pixels untouched")
            #expect(read(channelSurface(s), b) == ch0, "\(id): channel untouched")
            if changesGray(id) { #expect(read(maskSurface(s), b) != mask0, "\(id): the mask changed") }
            try s.execute("edit.undo")
            #expect(read(maskSurface(s), b) == mask0, "\(id): one undo step")
        }
    }

    @Test func retouchToolsPaintOnlyTheTargetedAlphaChannel() throws {
        for id in Self.runnableIds {
            let (s, state) = try targetedSession()
            let b = s.active!.doc.bounds
            let (px0, mask0, ch0) = (read(layerSurface(s), b), read(maskSurface(s), b), read(channelSurface(s), b))
            try s.execute(id, retouchParams(id, state, ["channel": 0]))
            #expect(read(layerSurface(s), b) == px0, "\(id): layer pixels untouched")
            #expect(read(maskSurface(s), b) == mask0, "\(id): mask untouched")
            if changesGray(id) { #expect(read(channelSurface(s), b) != ch0, "\(id): the channel changed") }
        }
    }

    @Test func retouchToolsFollowTheChannelsPanelTarget() throws {
        // No "target" param: the targeted alpha channel (Channels panel) is painted, like the Brush.
        for id in Self.runnableIds where changesGray(id) {
            let (s, state) = try targetedSession()
            let b = s.active!.doc.bounds
            let (px0, ch0) = (read(layerSurface(s), b), read(channelSurface(s), b))
            try s.updateActive { $0.channelView.target = .alpha(0) }
            #expect(s.isEnabled(id), "\(id)")
            try s.execute(id, retouchParams(id, state, nil))
            #expect(read(layerSurface(s), b) == px0, "\(id): layer pixels untouched")
            #expect(read(channelSurface(s), b) != ch0, "\(id): the channel changed")
        }
    }

    @Test func retouchToolsPaintTheQuickMask() throws {
        let (s, _) = try targetedSession()
        // Quick Mask mode over a selection of the left half (select.editInQuickMaskMode).
        try s.edit("Quick Mask") { doc, _ in
            var q = Surface(format: Channels.channelFormat(doc), defaultPixel: [0])
            q.fill(PixelRect(x0: 0, y0: 0, x1: 30, y1: 40), with: [1])
            doc.quickMask = AlphaChannel(name: "Quick Mask", surface: q)
        }
        let b = s.active!.doc.bounds
        let px0 = read(layerSurface(s), b)
        let q0 = read(s.active!.doc.quickMask?.surface, b)
        try s.execute("paint.smudge", ["points": [[20, 20], [45, 20]], "size": 12, "hardness": 100, "strength": 90])
        #expect(read(layerSurface(s), b) == px0, "layer pixels untouched")
        #expect(read(s.active!.doc.quickMask?.surface, b) != q0, "the Quick Mask changed")
    }

    @Test func retouchTargetsFailGracefully() throws {
        let s = try session(30, 30, 8, "rgb")
        for id in Self.retouchIds {
            func p(_ t: JSONValue) -> JSONValue { ["points": [[5, 5], [10, 5]], "size": 6, "state": 0, "offset": [1, 1], "target": t] }
            #expect(throws: EngineError.self, "\(id): no mask") { try s.execute(id, p("mask")) }
            #expect(throws: EngineError.self, "\(id): no channel 7") { try s.execute(id, p(["channel": 7])) }
            #expect(throws: EngineError.self, "\(id): not in Quick Mask mode") { try s.execute(id, p("quickMask")) }
            _ = try? s.execute(id, p(42))
            _ = try? s.execute(id, p(["channel": "x"]))
            _ = try? s.execute(id, ["points": [[5, 5]], "sampleAllLayers": "yes"])
        }
    }

    // MARK: Sample All Layers

    /// A Background with `bottom` and an empty layer above it (active).
    func twoLayers(_ bottom: (Int32, Int32) -> SIMD4<Float>) throws -> Session {
        let s = try session(100, 30, 8, "rgb")
        try paintLayer(s, bottom)
        try s.execute("layer.new.layer")
        return s
    }

    @Test func sampleAllLayersBlurAndSharpenWorkOnAnEmptyLayer() throws {
        let checker = { (x: Int32, y: Int32) -> SIMD4<Float> in (x + y) % 2 == 0 ? SIMD4(0.4, 0.4, 0.4, 1) : SIMD4(0.6, 0.6, 0.6, 1) }
        for (id, extra) in [("paint.blur", JSONValue.object([:])), ("paint.sharpen", ["protectDetail": false])] {
            func stroke(_ all: Bool) -> JSONValue {
                (["points": [[10, 15], [40, 15]], "size": 16, "hardness": 100, "strength": 100, "sampleAllLayers": .bool(all)] as JSONValue).merging(extra)
            }
            // Off: the empty layer has nothing to blur.
            let s = try twoLayers(checker)
            try s.execute(id, stroke(false))
            #expect(rgba(s, 25, 15).w == 0, "\(id): without Sample All Layers the layer stays empty")
            // On: the layer picks up the blurred / sharpened picture.
            let t = try twoLayers(checker)
            try t.execute(id, stroke(true))
            let (a, b) = (rgba(t, 25, 15), rgba(t, 26, 15))
            #expect(a.w > 0.99, "\(id): \(a)")
            let contrast = abs(a.x - b.x)
            if id == "paint.blur" { #expect(contrast < 0.1, "\(id): blurred (\(contrast))") } else { #expect(contrast > 0.25, "\(id): sharpened (\(contrast))") }
            #expect(rgba(t, 80, 15).w == 0, "\(id): outside the stroke untouched")
        }
    }

    @Test func sampleAllLayersSmudgeDragsColourFromBelow() throws {
        let edge = { (x: Int32, _: Int32) -> SIMD4<Float> in x < 30 ? SIMD4(1, 0, 0, 1) : SIMD4(1, 1, 1, 1) }
        func stroke(_ all: Bool) -> JSONValue { ["points": [[20, 15], [70, 15]], "size": 12, "hardness": 100, "strength": 80, "sampleAllLayers": .bool(all)] }
        let s = try twoLayers(edge)
        try s.execute("paint.smudge", stroke(false))
        #expect(rgba(s, 40, 15).w == 0, "without Sample All Layers the layer stays empty")
        let t = try twoLayers(edge)
        try t.execute("paint.smudge", stroke(true))
        let p = rgba(t, 36, 15)
        #expect(p.w > 0.99 && p.y < 0.6, "red dragged onto the empty layer: \(p)")
        // A mask target ignores Sample All Layers (nothing to sample from other layers).
        try t.execute("layer.layerMask.revealAll")
        try t.execute("paint.smudge", ["points": [[20, 25], [70, 25]], "size": 6, "sampleAllLayers": true, "target": "mask"])
    }

    @Test func smudgeAcrossATransparentEdgeHasNoDarkFringe() throws {
        for depth in Self.depths {
            let s = try session(100, 30, depth, "rgb")
            try s.execute("layer.new.layer")
            try paintLayer(s) { x, _ in x < 30 ? SIMD4(1, 0.8, 0, 1) : SIMD4(0, 0, 0, 0) }
            try s.execute("paint.smudge", ["points": [[20, 15], [70, 15]], "size": 12, "hardness": 50, "strength": 80])
            var n = 0
            for x: Int32 in 30..<80 {
                let p = rgba(s, x, 15)
                if p.w > 0.02 {
                    n += 1
                    #expect(p.x > 0.97 && abs(p.y - 0.8) < 0.03, "depth \(depth) x \(x): \(p)")
                }
            }
            #expect(n > 5, "depth \(depth): colour dragged into the transparent area")
        }
    }

    // MARK: Patch

    /// `texture` with a solid red blemish over `x0..<x0+8`, `y 20..<28`.
    static func blemished(_ x0: Int32) -> (Int32, Int32) -> SIMD4<Float> {
        { x, y in (x0..<(x0 + 8)).contains(x) && (20..<28).contains(y) ? SIMD4(1, 0, 0, 1) : texture(x, y) }
    }

    /// Every pixel of `rect` is within `t` of the clean texture.
    func expectRepaired(_ s: Session, _ r: (Int32, Int32, Int32, Int32), _ t: Float, _ what: String) {
        var worst: Float = 0
        for y in r.1..<r.3 {
            for x in r.0..<r.2 {
                let (got, want) = (rgba(s, x, y), Self.texture(x, y))
                for c in 0..<4 { worst = max(worst, abs(got[c] - want[c])) }
            }
        }
        #expect(worst < t, "\(what): worst \(worst)")
    }

    @Test func patchSourceRepairsTheSelectionWithTextureFromTheDragTarget() throws {
        for depth in Self.depths {
            let s = try session(96, 48, depth, "rgb")
            try paintLayer(s, Self.blemished(40))
            try s.execute("select.rect", ["x": 36, "y": 16, "width": 16, "height": 16])
            let r = try s.execute("paint.patch", ["offset": [-30, 2]])
            #expect(r["offset"] == [-30, 2])
            expectRepaired(s, (36, 16, 52, 32), 0.07, "depth \(depth)")
            // Outside the selection nothing changed, including the sampled area.
            for (x, y): (Int32, Int32) in [(35, 20), (52, 25), (10, 20), (44, 40)] {
                #expect(abs(rgba(s, x, y).x - Self.texture(x, y).x) <= tol(depth), "depth \(depth) untouched \(x),\(y)")
            }
            try s.execute("edit.undo")
            #expect(rgba(s, 44, 24).y == 0, "depth \(depth): undo brings the blemish back")
        }
    }

    @Test func patchContentAwareCopiesTheDraggedToContentIntoTheSelection() throws {
        // Photoshop's Patch: Content-Aware (measured on 25.4): only the selection changes; its
        // middle is the dragged-to content (Color 0 keeps its level), the edge band blends.
        for depth in [8, 16] {
            let s = try session(128, 64, depth, "rgb")
            try paintLayer(s, Self.blemished(40))
            try s.execute("select.rect", ["x": 32, "y": 12, "width": 24, "height": 24])
            let r = try s.execute("paint.patch", ["offset": [-30, 2], "contentAware": true, "structure": 7, "color": 0])
            #expect(r["contentAware"] == true)
            for (x, y): (Int32, Int32) in [(42, 22), (44, 24), (46, 26)] {
                let (got, want) = (rgba(s, x, y), Self.texture(x - 30, y + 2))
                for c in 0..<4 { #expect(abs(got[c] - want[c]) <= tol(depth), "depth \(depth): middle copied at \(x),\(y): \(got) vs \(want)") }
            }
            for (x, y): (Int32, Int32) in [(31, 20), (56, 25), (12, 20), (44, 40)] {
                #expect(abs(rgba(s, x, y).x - Self.texture(x, y).x) <= tol(depth), "depth \(depth): untouched \(x),\(y)")
            }
            #expect(s.active?.history.undoLabel == "Patch (Content-Aware)")
            try s.execute("edit.undo")
            #expect(rgba(s, 44, 24).y == 0, "depth \(depth): undo brings the blemish back")
        }
        // Bad options are refused before any work.
        let s = try session(96, 48, 8, "rgb")
        try paintLayer(s, Self.blemished(40))
        try s.execute("select.rect", ["x": 36, "y": 16, "width": 16, "height": 16])
        for p: JSONValue in [["offset": [-30, 0], "contentAware": true, "structure": 9], ["offset": [-30, 0], "contentAware": true, "color": -1]] {
            do { try s.execute("paint.patch", p); Issue.record("\(p)") } catch { #expect(isBadParams(error), "\(p): \(error)") }
        }
    }

    @Test func patchDestinationRepairsTheDragTargetFromTheSelection() throws {
        let s = try session(96, 48, 16, "rgb")
        try paintLayer(s, Self.blemished(40))
        // Select clean texture and drag it onto the blemish.
        try s.execute("select.rect", ["x": 6, "y": 16, "width": 16, "height": 16])
        try s.execute("paint.patch", ["offset": [30, 0], "mode": "destination"])
        expectRepaired(s, (36, 16, 52, 32), 0.07, "destination")
        #expect(abs(rgba(s, 10, 20).y - Self.texture(10, 20).y) < 1e-3, "source untouched")
        #expect(s.active!.history.undoLabel == "Patch (Destination)")
    }

    @Test func patchAtTheCanvasEdgeStaysOpaqueAndMatches() throws {
        let s = try session(64, 48, 8, "rgb")
        try paintLayer(s, Self.blemished(0))
        try s.execute("select.rect", ["x": 0, "y": 16, "width": 12, "height": 16])
        try s.execute("paint.patch", ["offset": [30, 0]])
        expectRepaired(s, (0, 16, 12, 32), 0.07, "edge")
    }

    @Test func patchFollowsAFeatheredSelectionAndAMaskTarget() throws {
        let s = try session(96, 48, 8, "rgb")
        try paintLayer(s, Self.blemished(40))
        try s.execute("select.rect", ["x": 36, "y": 16, "width": 16, "height": 16, "ellipse": true, "feather": 2])
        try s.execute("paint.patch", ["offset": [-30, 0]])
        // The blemish (well inside the ellipse) is gone, a corner outside the ellipse is untouched.
        expectRepaired(s, (42, 22, 46, 26), 0.07, "feathered")
        #expect(abs(rgba(s, 36, 16).x - Self.texture(36, 16).x) <= tol(8), "corner outside the ellipse")
        try s.execute("layer.layerMask.revealAll")
        try s.execute("paint.patch", ["offset": [-30, 0], "target": "mask"])
    }

    @Test func patchFailsGracefully() throws {
        let s = try session(64, 48, 8, "rgb")
        #expect(throws: EngineError.self, "no selection") { try s.execute("paint.patch", ["offset": [10, 0]]) }
        try s.execute("select.rect", ["x": 10, "y": 10, "width": 10, "height": 10])
        let cases: [JSONValue] = [
            [:], ["offset": [10]], ["offset": "far"], ["offset": [1e300, 0]], ["offset": [0, 0]], ["offset": [10, 0], "mode": "bogus"],
            ["offset": [60, 0]], ["offset": [0, -30]], ["offset": [10, 0], "target": "mask"], ["offset": [10, 0], "target": ["channel": 7]],
            ["offset": [10, 0], "layer": 999],
        ]
        for p in cases { #expect(throws: EngineError.self, "\(p)") { try s.execute("paint.patch", p) } }
        #expect(throws: Never.self) { try s.execute("paint.patch", ["offset": [10, 0]]) }
    }

    @Test func patchPreviewMatchesTheCommandAndItsCoarseSolveIsClose() throws {
        let s = try session(160, 96, 16, "rgb")
        try paintLayer(s, Self.blemished(100))
        try s.execute("select.rect", ["x": 80, "y": 4, "width": 60, "height": 60, "ellipse": true, "feather": 3])
        let p: JSONValue = ["offset": [-70, 20]]
        let rev = s.active!.revision
        let id = s.active!.activeLayer!
        func layer(_ d: Document, _ x: Int32, _ y: Int32) -> SIMD4<Float> { d.layer(id)?.surface?.rgba(x: x, y: y) ?? .zero }
        let (exact, dmg) = try RetouchCommands.patchPreview(s, p, maxCells: .max, minStep: 1)
        let (coarse, _) = try RetouchCommands.patchPreview(s, p, maxCells: 64, minStep: 1)
        #expect(dmg.contains(x: 104, y: 24) && !dmg.contains(x: 20, y: 24), "\(dmg)")
        #expect(s.active!.revision == rev, "the preview records nothing")
        try s.execute("paint.patch", p)
        let committed = s.active!.doc
        var worst: Float = 0
        var exactMatches = true
        for y: Int32 in 0..<96 {
            for x: Int32 in 0..<160 {
                let (e, c, d) = (layer(exact, x, y), layer(coarse, x, y), layer(committed, x, y))
                for k in 0..<4 {
                    if abs(e[k] - d[k]) >= 1e-6 { exactMatches = false }
                    worst = max(worst, abs(c[k] - d[k]))
                }
            }
        }
        #expect(exactMatches, "step 1 is the command")
        // 64 cells over a ~64² patch: an 8× coarser membrane, all of the difference in the colour fit.
        #expect(worst < 0.03, "coarse preview off by \(worst)")
        #expect(throws: EngineError.self) { try RetouchCommands.patchPreview(s, ["offset": [500, 0]], maxCells: 64, minStep: 1) }
    }

    // MARK: Pattern Stamp

    @discardableResult
    func stamp(_ s: Session, _ extra: JSONValue) throws -> JSONValue {
        let p: JSONValue = ["points": [[16, 16]], "size": 16, "hardness": 100, "pattern": "Checkerboard", "scale": 100, "aligned": true]
        return try s.execute("paint.patternStamp", p.merging(extra))
    }

    static func checkerAt(_ x: Int32, _ y: Int32) -> Float {
        func de(_ v: Int32) -> Int32 { v >= 0 ? v / 8 : -((-v + 7) / 8) }
        return ((de(x) + de(y)) % 2 + 2) % 2 == 0 ? 0.8 : 1
    }

    @Test func patternStampPaintsTheTileAtEveryDepthAndUndoes() throws {
        for depth in Self.depths {
            let s = try session(64, 48, depth, "rgb")
            let before = rgba(s, 16, 16)
            let r = try stamp(s, ["points": [[16, 16]]])
            #expect(r["aligned"] == true)
            #expect(r["phase"] == [0.0, 0.0])
            #expect(r["pattern"]?.stringValue?.isEmpty == false, "\(r)")
            let got = rgba(s, 16, 16), want = Self.checkerAt(16, 16)
            for c in 0..<3 { #expect(abs(got[c] - want) <= tol(depth), "depth \(depth) \(got) want \(want)") }
            #expect(got.w > 0.99, "\(got)")
            #expect(got != before)
            #expect(s.active!.doc.patterns.contains { $0.name == "Checkerboard" })
            #expect(s.undo())
            #expect(abs(rgba(s, 16, 16).x - before.x) <= tol(depth))
            #expect(s.redo())
            #expect(abs(rgba(s, 16, 16).x - want) <= tol(depth))
        }
        let g = try session(48, 32, 16, "gray")
        try stamp(g, ["points": [[16, 16]]])
        #expect(abs(rgba(g, 16, 16).x - Self.checkerAt(16, 16)) <= tol(16))
    }

    @Test func patternStampIntegerScaleReproducesTheTileInTheDab() throws {
        let s = try session(32, 32, 8, "rgb")
        try stamp(s, ["points": [[8, 8]], "size": 16, "hardness": 100, "phase": [0, 0]])
        for (x, y): (Int32, Int32) in [(8, 8), (10, 8), (8, 12)] {
            let (got, want) = (rgba(s, x, y), Self.checkerAt(x, y))
            #expect(abs(got.x - want) <= tol(8) && abs(got.y - want) <= tol(8), "(\(x),\(y)) \(got) want \(want)")
        }
    }

    @Test func patternStampScaledTilesHaveNoGaps() throws {
        for scale in [50.0, 200.0] {
            let s = try session(64, 48, 8, "rgb")
            try stamp(s, ["points": [[24, 24]], "size": 24, "hardness": 100, "scale": .number(scale), "phase": [0, 0]])
            var holes = 0
            for y: Int32 in 20..<28 { for x: Int32 in 20..<28 where rgba(s, x, y).w < 0.5 { holes += 1 } }
            #expect(holes == 0, "scale \(scale): transparent holes inside the dab")
        }
    }

    @Test func patternStampAlignedKeepsDocumentPhaseAcrossStrokes() throws {
        let s = try session(80, 40, 8, "rgb")
        try stamp(s, ["points": [[10, 16]], "size": 8, "hardness": 100, "aligned": true, "phase": [0, 0]])
        let a = rgba(s, 10, 16)
        try stamp(s, ["points": [[18, 16]], "size": 8, "hardness": 100, "aligned": true, "phase": [0, 0]])
        let b = rgba(s, 18, 16)
        #expect(abs(a.x - Self.checkerAt(10, 16)) <= tol(8), "\(a)")
        #expect(abs(b.x - Self.checkerAt(18, 16)) <= tol(8), "\(b)")
        #expect(abs(a.x - b.x) > 0.05, "aligned wallpaper: (10,16) and (18,16) sit on different cells")
    }

    @Test func patternStampUnalignedRestartsAtEachStroke() throws {
        let s = try session(80, 40, 8, "rgb")
        let r1 = try stamp(s, ["points": [[10, 16]], "size": 8, "hardness": 100, "aligned": false])
        #expect(r1["phase"] == [10.0, 16.0])
        let a = rgba(s, 10, 16)
        let r2 = try stamp(s, ["points": [[40, 16]], "size": 8, "hardness": 100, "aligned": false])
        #expect(r2["phase"] == [40.0, 16.0])
        #expect(abs(a.x - rgba(s, 40, 16).x) <= tol(8), "each stroke's first point is the tile origin")
    }

    @Test func patternStampImpressionistIsSeededAndReplayable() throws {
        let params: JSONValue = ["points": [[20, 20], [36, 22], [52, 20]], "size": 12, "hardness": 80, "pattern": "Bricks", "impressionist": true, "aligned": true]
        let a = try session(80, 40, 8, "rgb")
        try a.execute("paint.patternStamp", params)
        let xs: [Int32] = [20, 36, 52]
        let samples = xs.map { rgba(a, $0, 20) }
        #expect(a.undo())
        try a.execute("paint.patternStamp", params)
        for (i, x) in xs.enumerated() {
            let got = rgba(a, x, 20)
            for c in 0..<4 { #expect(abs(got[c] - samples[i][c]) < 1e-6, "replay x=\(x) \(got) vs \(samples[i])") }
        }
        let b = try session(80, 40, 8, "rgb")
        try b.execute("paint.patternStamp", params.setting("impressionist", false))
        let (smooth, noisy) = (rgba(b, 36, 20), samples[1])
        #expect(abs(noisy.x - smooth.x) > 1e-4 || abs(noisy.y - smooth.y) > 1e-4, "impressionist should jitter the phase: \(noisy) vs \(smooth)")
    }

    @Test func patternStampTileSeamMatchesAnUntiledReference() throws {
        let s = try session(96, 96, 8, "rgb")
        try stamp(s, ["points": [[64, 48]], "size": 32, "hardness": 100, "phase": [0, 0]])
        let pat = try #require(Self.library.first { $0.name == "Checkerboard" })
        let tile = PatternTile(id: pat.id, name: pat.name, width: Int(pat.width), height: Int(pat.height), straight: pat.surface.readRGBA(pat.rect))
        let reference = RetouchCommands.renderPattern(tile, RetouchCommands.placement(.zero, 1, 0), PixelRect(x0: 64, y0: 40, x1: 65, y1: 56))
        for (i, y) in (Int32(40)..<56).enumerated() {
            let got = rgba(s, 64, y)
            for c in 0..<3 { #expect(abs(got[c] - reference[i][c]) <= tol(8), "y=\(y) \(got) vs \(reference[i])") }
        }
    }

    @Test func patternStampRejectsHostileInput() throws {
        let s = try session(64, 48, 8, "rgb")
        let cases: [JSONValue] = [
            ["points": [], "pattern": "Checkerboard"], ["pattern": "Checkerboard"], ["points": [[16, 16]], "pattern": "no-such-pattern"],
            ["points": [[16, 16]], "pattern": "Checkerboard", "size": 1e30], ["points": [[1e7, 0]], "pattern": "Checkerboard", "size": 8],
            ["points": [[.number(.nan), 0]], "pattern": "Checkerboard", "size": 8],
            ["points": [[0, 0], [9000, 9000]], "pattern": "Checkerboard", "size": 5000, "hardness": 100],
            ["points": [[8, 8]], "pattern": "EmptyTile", "size": 8],
        ]
        for p in cases { #expect(throws: EngineError.self, "\(p)") { try s.execute("paint.patternStamp", p) } }
        try s.execute("layer.setProps", ["locks": ["pixels": true]])
        #expect(throws: EngineError.self) { try stamp(s, ["points": [[16, 16]]]) }
    }

    @Test func aDiagonalAcrossA24MPCanvasIsNotTooLarge() {
        func stroke(_ pts: [(Double, Double)], _ size: Float) -> Stroke {
            var b = BrushSettings()
            b.size = size
            return Stroke(brush: b, points: pts.map { StrokePoint($0.0, $0.1, 1) })
        }
        #expect(throws: Never.self) { try RetouchCommands.rejectHugeStroke("t", stroke([(0, 0), (6015, 3999)], 100)) }
        #expect(throws: Never.self) { try RetouchCommands.rejectBounds("t", PixelRect(x: -60, y: -60, width: 6136, height: 4120)) }
        #expect(throws: EngineError.self) { try RetouchCommands.rejectHugeStroke("t", stroke([(0, 0), (9000, 9000)], 100)) }
        #expect(throws: EngineError.self) { try RetouchCommands.rejectBounds("t", PixelRect(x: 0, y: 0, width: 9000, height: 9000)) }
    }

    @Test func retouchStrokesRefuseAbsurdPointCoordinates() throws {
        // #976: every retouch tool's `points` must stay within ±1e6, as the painting tools' do.
        let far: [JSONValue] = [[[1_000_001, 0]], [[0, 0], [0, -2_000_000]], [[0, 0], [1e300, 0]], [[1e300, 1e300]]]
        for depth in Self.depths {
            let s = try session(32, 32, depth, "rgb")
            try paintLayer(s) { x, y in SIMD4(Float(x) / 32, Float(y) / 32, 0.25, 1) }
            try s.execute("cloneSource.set", ["source": [8, 8]])
            let (before, past) = (rgba(s, 16, 16), s.active!.history.pastCount)
            for cmd in Self.runnableIds {
                for points in far {
                    do {
                        try s.execute(cmd, ["points": points])
                        Issue.record("\(cmd) \(points) ran")
                    } catch {
                        #expect(String(describing: error).contains("within ±"), "\(cmd) \(points) at \(depth): \(error)")
                    }
                }
            }
            #expect(rgba(s, 16, 16) == before && s.active!.history.pastCount == past, "\(depth): nothing changed")
            // Control: a stroke on the canvas still retouches.
            try s.execute("paint.dodge", ["points": [[4, 16], [28, 16]], "size": 8])
            #expect(rgba(s, 16, 16) != before, "\(depth)")
        }
    }

    // MARK: photocraft-algo poisson.rs (through PCAlgo's `Poisson`)

    /// Reference solver for tests (photocraft-algo's test helper): plain Gauss–Seidel from a zero
    /// start until the update is below `tolerance`.
    static func solveMembraneReference(_ w: Int, _ h: Int, _ unknown: [Bool], _ v: inout [Float], _ tolerance: Float, _ maxIter: Int) {
        for i in v.indices where unknown[i] { v[i] = 0 }
        for _ in 0..<maxIter {
            var maxD: Float = 0
            for y in 0..<h {
                for x in 0..<w where unknown[y * w + x] {
                    var s: Float = 0, n: Float = 0
                    for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] where nx >= 0 && ny >= 0 && nx < w && ny < h {
                        s += v[ny * w + nx]
                        n += 1
                    }
                    if n > 0 {
                        let nv = s / n
                        maxD = Float.maximum(maxD, abs(nv - v[y * w + x]))
                        v[y * w + x] = nv
                    }
                }
            }
            if maxD < tolerance { break }
        }
    }

    func disc(_ w: Int, _ h: Int, _ cx: Float, _ cy: Float, _ r: Float) -> [Bool] {
        (0..<(w * h)).map { hypot(Float($0 % w) - cx, Float($0 / w) - cy) < r }
    }

    @Test func membraneReproducesLinearBoundary() {
        // A linear function is harmonic: the solve must reproduce it inside the hole.
        let (w, h) = (80, 60)
        let unknown = disc(w, h, 40, 30, 20)
        let truth = (0..<(w * h)).map { 0.2 + 0.005 * Float($0 % w) + 0.003 * Float($0 / w) }
        var v = zip(truth, unknown).map { $1 ? 0 : $0 }
        RetouchCommands.Kernels.solveMembrane(w, h, unknown, &v)
        let err = zip(v, truth).reduce(Float(0)) { max($0, abs($1.0 - $1.1)) }
        #expect(err < 2e-3, "\(err)")
    }

    @Test func multigridMatchesReferenceSolve() {
        let (w, h) = (96, 72)
        let unknown = disc(w, h, 45, 36, 28)
        let initial = (0..<(w * h)).map { sin(Float($0 % w) * 0.21) * 0.3 + cos(Float($0 / w) * 0.13) * 0.2 + 0.5 }
        var fast = initial
        RetouchCommands.Kernels.solveMembrane(w, h, unknown, &fast)
        var reference = initial
        Self.solveMembraneReference(w, h, unknown, &reference, 1e-7, 100_000)
        let err = zip(fast, reference).reduce(Float(0)) { max($0, abs($1.0 - $1.1)) }
        #expect(err < 2e-3, "max error vs reference \(err)")
        #expect((0..<(w * h)).allSatisfy { unknown[$0] || fast[$0] == initial[$0] }, "known pixels untouched")
    }

    @Test func seamlessCloneTakesDestinationColourAndSourceTexture() {
        let (w, h, ch) = (64, 64, 3)
        let mask = disc(w, h, 32, 32, 20)
        let dst: [Float] = (0..<(w * h)).flatMap { _ -> [Float] in [0.7, 0.3, 0.2] }
        let src: [Float] = (0..<(w * h)).flatMap { i -> [Float] in
            let t: Float = (i % w / 4) % 2 == 0 ? 0.05 : -0.05
            return [0.1 + t, 0.2 + t, 0.8 + t]
        }
        let out = RetouchCommands.Kernels.seamlessClone(w, h, ch, src, dst, mask)
        let inside = (0..<(w * h)).filter { mask[$0] }
        for c in 0..<ch {
            let m = inside.reduce(Float(0)) { $0 + out[$1 * ch + c] } / Float(inside.count)
            #expect(abs(m - dst[c]) < 0.02, "channel \(c) mean \(m)")
        }
        var (e, n): (Float, Int) = (0, 0)
        for i in inside where mask[i + 1] {
            e += abs((out[(i + 1) * ch] - out[i * ch]) - (src[(i + 1) * ch] - src[i * ch]))
            n += 1
        }
        #expect(e / Float(n) < 0.01, "gradient error \(e / Float(n))")
        #expect(Array(out[0..<3]) == Array(dst[0..<3]))
    }

    // MARK: photocraft-algo retouch.rs

    @Test func dodgeMidtonesAffectsMidtonesMost() {
        func g(_ v: Float) -> Float { RetouchCommands.Kernels.dodgeBurn(SIMD3(repeating: v), 0.5, .midtones, false, true).x - v }
        #expect(g(0.5) > 0.1)
        #expect(g(0.5) > 2 * g(0.1))
        #expect(g(0.5) > 2 * g(0.95))
        #expect(RetouchCommands.Kernels.dodgeBurn(.zero, 0.5, .midtones, false, true) == .zero)
        #expect(RetouchCommands.Kernels.dodgeBurn(SIMD3(repeating: 0.5), 0.5, .midtones, true, true).x < 0.45)
    }

    @Test func rangesTargetTheirTones() {
        func d(_ v: Float, _ r: RetouchCommands.ToneRange) -> Float { RetouchCommands.Kernels.toneCurve(v, 0.5, r, false) - v }
        #expect(d(0.1, .shadows) > d(0.9, .shadows))
        #expect(d(0.9, .highlights) > d(0.1, .highlights))
        func b(_ v: Float, _ r: RetouchCommands.ToneRange) -> Float { v - RetouchCommands.Kernels.toneCurve(v, 0.5, r, true) }
        #expect(b(0.9, .highlights) > b(0.2, .highlights))
        #expect(b(0.3, .shadows) / 0.3 > b(0.9, .shadows) / 0.9)
    }

    @Test func protectTonesKeepsHue() {
        let c = SIMD3<Float>(0.6, 0.3, 0.2)
        let p = RetouchCommands.Kernels.dodgeBurn(c, 0.8, .midtones, false, true)
        #expect((0..<3).allSatisfy { p[$0] >= 0 && p[$0] <= 1 })
        #expect(abs(p.x / p.y - c.x / c.y) < 0.05, "\(p)")
    }

    @Test func spongeChangesSaturation() {
        let c = SIMD3<Float>(0.8, 0.4, 0.3)
        let d = RetouchCommands.Kernels.sponge(c, 0.5, false, false)
        #expect(RetouchCommands.Kernels.saturation(d) < RetouchCommands.Kernels.saturation(c))
        #expect(abs(RetouchCommands.Kernels.luma(d) - RetouchCommands.Kernels.luma(c)) < 1e-4)
        let s = RetouchCommands.Kernels.sponge(c, 0.5, true, false)
        #expect(RetouchCommands.Kernels.saturation(s) > RetouchCommands.Kernels.saturation(c))
        #expect((0..<3).allSatisfy { s[$0] >= 0 && s[$0] <= 1 })
        let v = RetouchCommands.Kernels.sponge(SIMD3(1, 0.1, 0.1), 0.5, true, true)
        let nv = RetouchCommands.Kernels.sponge(SIMD3(1, 0.1, 0.1), 0.5, true, false)
        #expect(abs(v.y - 0.1) <= abs(nv.y - 0.1))
        #expect(RetouchCommands.Kernels.sponge(SIMD3(repeating: 0.5), 1, false, false) == SIMD3(repeating: 0.5))
    }

    @Test func blurReducesVarianceAndSharpenIncreasesIt() {
        let (w, h, ch) = (16, 16, 1)
        func vari(_ v: [Float]) -> Float {
            let m = v.reduce(0, +) / Float(v.count)
            return v.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Float(v.count)
        }
        func window(_ d: [Float]) -> [Float] { (4..<12).flatMap { y in (4..<12).map { x in d[y * w + x] } } }
        let data = (0..<(w * h)).map { Float(($0 % w + $0 / w) % 2 == 0 ? 0.2 : 0.8) }
        let win = (4, 4, 12, 12)
        #expect(vari(RetouchCommands.Kernels.localBlur(data, w, h, ch, nil, win, 1.5)) < vari(window(data)) * 0.2)
        let smooth = (0..<(w * h)).map { 0.3 + 0.03 * Float($0 % w) + ($0 % w == 8 ? 0.2 : 0) }
        #expect(vari(RetouchCommands.Kernels.localSharpen(smooth, w, h, ch, nil, win, 1, false)) > vari(window(smooth)))
        let hi = smooth.max() ?? 0
        #expect(RetouchCommands.Kernels.localSharpen(smooth, w, h, ch, nil, win, 4, true).allSatisfy { $0 <= hi + 1e-6 })
    }

    @Test func blurIgnoresTransparentColour() {
        // Red opaque next to transparent green: blurred colour stays red.
        let (w, h, ch) = (8, 1, 4)
        let data: [Float] = (0..<w).flatMap { x -> [Float] in x < 4 ? [1, 0, 0, 1] : [0, 1, 0, 0] }
        let b = RetouchCommands.Kernels.localBlur(data, w, h, ch, 3, (2, 0, 6, 1), 1)
        for i in stride(from: 0, to: b.count, by: 4) where b[i + 3] > 0.01 {
            #expect(b[i] > 0.99 && b[i + 1] < 0.01, "\(Array(b[i..<i + 4]))")
        }
    }
}

// MARK: - Spot Healing, Content-Aware Move (PCAlgo inpainting)

extension RetouchTests {
    // MARK: Proximity Match source patch

    @Test func proximityMatchReadsOriginalPixelsForOverlappingOffsets() throws {
        // Shifting the source one pixel to the left overlaps the destination in a left-to-right
        // traversal: reading the output would repeat the first value.
        let img: [Float] = [10, 20, 30, 40, 50, 60]
        let mask = [false, true, true, true, false, false]
        let result = try #require(RetouchCommands.proximitySourcePatch(img, 6, 1, 1, mask, -1, 0))
        #expect(result == [10, 10, 20, 30, 50, 60])
        #expect(img == [10, 20, 30, 40, 50, 60], "source remains untouched")
    }

    @Test func proximityMatchPreservesChannelsAndUnmaskedPixels() throws {
        // A two-channel image shifted from the row above.
        let img: [Float] = [1, 2, 3, 4, 5, 6, 7, 8]
        let result = try #require(RetouchCommands.proximitySourcePatch(img, 2, 2, 2, [false, false, true, false], 0, -1))
        #expect(result == [1, 2, 3, 4, 1, 2, 7, 8])
    }

    @Test func proximityMatchRejectsInvalidTranslationsWithoutTrapping() {
        let img: [Float] = [1, 2, 3, 4]
        let mask = [true, false, false, false]
        #expect(RetouchCommands.proximitySourcePatch(img, 2, 2, 1, mask, -1, 0) == nil)
        #expect(RetouchCommands.proximitySourcePatch(img, 2, 2, 1, mask, 0, -1) == nil)
        #expect(RetouchCommands.proximitySourcePatch(img, 2, 2, 1, mask, Int32.max, 0) == nil)
        #expect(RetouchCommands.proximitySourcePatch(img, 2, 2, 1, Array(mask[..<3]), 0, 0) == nil)
        #expect(RetouchCommands.proximitySourcePatch(img, Int.max, 2, 1, mask, 0, 0) == nil)
    }

    // MARK: Spot Healing

    @Test func spotHealingRemovesBlemishAllTypes() throws {
        for (depth, kind) in [(8, "contentAware"), (16, "contentAware"), (32, "contentAware"), (8, "proximityMatch"), (16, "createTexture")] {
            let s = try session(160, 120, depth, "rgb")
            try paintLayer(s) { x, y in
                hypot(Float(x - 80), Float(y - 60)) < 6 ? SIMD4(0.05, 0.03, 0.02, 1) : Self.texture(x, y)
            }
            func err() -> Float {
                var (e, n): (Float, Int) = (0, 0)
                for y: Int32 in 52...68 {
                    for x: Int32 in 72...88 {
                        let (p, t) = (rgba(s, x, y), Self.texture(x, y))
                        for c in 0..<3 { e += (p[c] - t[c]) * (p[c] - t[c]) }
                        n += 3
                    }
                }
                return (e / Float(n)).squareRoot()
            }
            let before = err()
            try s.execute("paint.spotHealing", ["points": [[80, 60]], "size": 20, "hardness": 100, "type": .string(kind)])
            let after = err()
            #expect(after < 0.05 && after < before * 0.2, "\(kind) depth \(depth): rmse \(before) → \(after)")
            // Far away untouched.
            #expect(abs(rgba(s, 10, 10).x - Self.texture(10, 10).x) <= tol(depth) + 1e-3)
        }
    }

    @Test func sampleAllLayersSpotHealingHealsOntoAnEmptyLayer() throws {
        // #731: the blemish below is healed onto the empty layer.
        for depth in Self.depths {
            func heal(_ all: Bool) throws -> Session {
                let s = try session(100, 30, depth, "rgb")
                try paintLayer(s, Self.blemished(46))
                try s.execute("layer.new.layer")
                try s.execute("paint.spotHealing", ["points": [[50, 24]], "size": 12, "hardness": 100, "sampleAllLayers": .bool(all)])
                return s
            }
            #expect(rgba(try heal(false), 50, 24).w == 0, "depth \(depth): without Sample All Layers the layer stays empty")
            let s = try heal(true)
            let (p, t) = (rgba(s, 50, 24), Self.texture(50, 24))
            #expect(p.w > 0.99 && abs(p.x - t.x) < 0.1 && abs(p.y - t.y) < 0.1, "depth \(depth): healed, not red: \(p) want \(t)")
            #expect(rgba(s, 80, 15).w == 0, "depth \(depth): outside the stroke untouched")
        }
    }

    // MARK: Content-Aware Move

    /// `texture` with a solid blue object over `x0..<x0+12`, `y0..<y0+12`.
    static func withObject(_ x0: Int32, _ y0: Int32) -> (Int32, Int32) -> SIMD4<Float> {
        { x, y in (x0..<(x0 + 12)).contains(x) && (y0..<(y0 + 12)).contains(y) ? SIMD4(0.05, 0.1, 0.9, 1) : texture(x, y) }
    }

    func isObject(_ px: SIMD4<Float>) -> Bool { px.z > 0.8 && px.x < 0.2 }

    func selected(_ s: Session, _ x: Int32, _ y: Int32) -> Bool { (s.active?.doc.selection?.sampleChannel(x: x, y: y, 0) ?? 0) > 0 }

    @Test func contentAwareMoveMovesTheObjectAndFillsItsPlaceAtAllDepths() throws {
        for depth in Self.depths {
            let s = try session(128, 64, depth, "rgb")
            try paintLayer(s, Self.withObject(20, 26))
            try s.execute("select.rect", ["x": 16, "y": 22, "width": 20, "height": 20])
            let r = try s.execute("paint.contentAwareMove", ["offset": [70, 0]])
            #expect(r["offset"] == [70, 0])
            #expect(r["mode"] == "move")
            // The object's core is at the new place; its old place holds texture again.
            for (x, y): (Int32, Int32) in [(93, 32), (95, 30), (98, 35)] {
                #expect(isObject(rgba(s, x, y)), "depth \(depth): object at \(x),\(y): \(rgba(s, x, y))")
            }
            var stale = 0
            for y: Int32 in 26..<38 { for x: Int32 in 20..<32 where isObject(rgba(s, x, y)) { stale += 1 } }
            #expect(stale == 0, "depth \(depth): the old place still shows the object at \(stale) pixels")
            // Far away nothing changed.
            for (x, y): (Int32, Int32) in [(2, 2), (60, 60), (125, 5)] {
                #expect(abs(rgba(s, x, y).x - Self.texture(x, y).x) <= tol(depth), "depth \(depth): \(x),\(y) changed")
            }
            // The selection followed the content.
            #expect(selected(s, 96, 32) && !selected(s, 26, 32), "depth \(depth): selection moved")
            // One step: undo restores pixels and selection, redo brings the move back.
            try s.execute("edit.undo")
            #expect(isObject(rgba(s, 25, 31)) && !isObject(rgba(s, 95, 31)), "depth \(depth): undo restores the object")
            #expect(selected(s, 26, 32) && !selected(s, 96, 32), "depth \(depth): undo restores the selection")
            try s.execute("edit.redo")
            #expect(isObject(rgba(s, 95, 31)) && !isObject(rgba(s, 25, 31)), "depth \(depth): redo")
        }
    }

    @Test func contentAwareMoveTransformOnDropScalesAndRotatesTheContent() throws {
        // A horizontal 16×6 bar in a 36×36 selection, dropped 80 px right and turned 90° with 125%
        // width: it lands upright, 20 px tall, and the blend works around the turned content.
        let bar = { (x: Int32, y: Int32) -> SIMD4<Float> in
            (20..<36).contains(x) && (30..<36).contains(y) ? SIMD4(0.05, 0.1, 0.9, 1) : Self.texture(x, y)
        }
        for depth in [8, 32] {
            let s = try session(160, 64, depth, "rgb")
            try paintLayer(s, bar)
            try s.execute("select.rect", ["x": 10, "y": 15, "width": 36, "height": 36])
            let r = try s.execute("paint.contentAwareMove", ["offset": [80, 0], "rotate": 90, "scaleX": 125])
            #expect(r["transformed"] == true)
            for (x, y): (Int32, Int32) in [(108, 24), (108, 33), (108, 42), (106, 30)] {
                #expect(isObject(rgba(s, x, y)), "depth \(depth): the turned, stretched bar covers \(x),\(y): \(rgba(s, x, y))")
            }
            for (x, y): (Int32, Int32) in [(101, 33), (115, 33)] {
                #expect(!isObject(rgba(s, x, y)), "depth \(depth): no unturned bar at \(x),\(y)")
            }
            #expect(!isObject(rgba(s, 28, 33)), "depth \(depth): the old place is filled")
            #expect(selected(s, 108, 33) && !selected(s, 28, 33), "depth \(depth): the selection followed")
            // One step: undo brings the bar and the selection back.
            try s.execute("edit.undo")
            #expect(isObject(rgba(s, 28, 33)) && !isObject(rgba(s, 108, 24)), "depth \(depth): undo")
            #expect(selected(s, 28, 33), "depth \(depth): undo restores the selection")
        }
    }

    @Test func contentAwareExtendKeepsTheOriginal() throws {
        let s = try session(128, 64, 8, "rgb")
        try paintLayer(s, Self.withObject(20, 26))
        try s.execute("select.rect", ["x": 16, "y": 22, "width": 20, "height": 20])
        let r = try s.execute("paint.contentAwareMove", ["offset": [60, -10], "mode": "extend"])
        #expect(r["mode"] == "extend")
        #expect(isObject(rgba(s, 25, 31)), "the original stays")
        #expect(isObject(rgba(s, 85, 21)), "the copy lands")
        #expect(s.active?.history.undoLabel == "Content-Aware Extend")
    }

    @Test func contentAwareMoveStructureAndColorShapeTheResult() throws {
        // Structure 7, Color 0: the content is copied exactly but for a band about a patch wide
        // along its edge, which blends into the new surroundings; Structure 3 gives the same, bit
        // for bit (as in Photoshop).
        func moved(_ structure: Int) throws -> Session {
            let s = try session(128, 64, 16, "rgb")
            try paintLayer(s, Self.texture)
            try s.execute("select.rect", ["x": 10, "y": 10, "width": 24, "height": 24])
            try s.execute("paint.contentAwareMove", ["offset": [70, 20], "structure": .int(structure), "mode": "extend"])
            return s
        }
        let s7 = try moved(7)
        for (x, y): (Int32, Int32) in [(16, 16), (22, 22), (27, 27)] {
            let (got, want) = (rgba(s7, x + 70, y + 20), Self.texture(x, y))
            for c in 0..<4 { #expect(abs(got[c] - want[c]) <= tol(16), "strict copy at \(x),\(y): \(got) vs \(want)") }
        }
        let s3 = try moved(3)
        var differ = 0
        for y: Int32 in 30..<54 { for x: Int32 in 80..<104 where rgba(s7, x, y) != rgba(s3, x, y) { differ += 1 } }
        #expect(differ == 0, "structure 3 and 7 agree (\(differ) pixels differ)")
        // Structure 2 widens the re-synthesised band: the edge differs from a plain copy, the centre
        // doesn't. Structure 1 re-synthesises the content too, its centre included.
        func copy(_ s: Session, _ x: Int32, _ y: Int32) -> (SIMD4<Float>, SIMD4<Float>) { (rgba(s, x + 70, y + 20), rgba(s, x, y)) }
        let s2 = try moved(2)
        let (centre, orig) = copy(s2, 22, 22)
        #expect(centre == orig, "the centre is kept")
        let edge = (Int32(0)..<24).filter { i in copy(s2, 10 + i, 10).0 != copy(s2, 10 + i, 10).1 }.count
        #expect(edge > 12, "the top edge row is blended in (\(edge) of 24 pixels differ)")
        let s1 = try moved(1)
        let (c1, o1) = copy(s1, 22, 22)
        #expect(c1 != o1, "structure 1 re-synthesises the centre too")

        // Color 10 fits a bright patch to a dark place; Color 0 keeps it bright.
        func mean(_ color: Int) throws -> Float {
            let s = try session(128, 64, 32, "rgb")
            try paintLayer(s) { x, _ in x < 64 ? SIMD4(0.8, 0.8, 0.8, 1) : SIMD4(0.2, 0.2, 0.2, 1) }
            try s.execute("select.rect", ["x": 20, "y": 20, "width": 24, "height": 24])
            try s.execute("paint.contentAwareMove", ["offset": [70, 0], "structure": 7, "color": .int(color), "mode": "extend"])
            // The copied middle (the edge band is re-synthesised from the dark surroundings).
            return (Int32(98)..<106).map { rgba(s, $0, 32).x }.reduce(0, +) / 8
        }
        let (kept, some, fitted) = (try mean(0), try mean(3), try mean(10))
        #expect(abs(kept - 0.8) < 1e-3, "color 0 keeps the colour: \(kept)")
        // Photoshop shifts by up to about 0.04 per step of Color.
        #expect(abs(some - 0.68) < 0.03, "color 3 adapts part of the way: \(some)")
        #expect(abs(fitted - 0.4) < 0.03, "color 10 adapts most of the way: \(fitted)")
    }

    @Test func contentAwareMoveOverlappingAtTheEdgeAndOnOtherTargets() throws {
        // A short drag (the content overlaps its old place) from the canvas edge.
        let s = try session(96, 48, 8, "rgb")
        try paintLayer(s, Self.withObject(0, 18))
        try s.execute("select.rect", ["x": 0, "y": 14, "width": 16, "height": 20])
        try s.execute("paint.contentAwareMove", ["offset": [8, 0]])
        #expect(isObject(rgba(s, 14, 24)), "object moved right")
        #expect(!isObject(rgba(s, 2, 24)), "its old left part is filled: \(rgba(s, 2, 24))")
        #expect(rgba(s, 0, 24).w > 0.99, "the edge stays opaque")

        // On a transparent layer the old place becomes transparent like its surroundings.
        let t = try session(96, 48, 8, "rgb")
        try t.execute("layer.new.layer")
        try t.execute("paint.pencil", ["points": [[30, 24]], "size": 10, "color": "#1020e0"])
        try t.execute("select.rect", ["x": 20, "y": 14, "width": 20, "height": 20])
        try t.execute("paint.contentAwareMove", ["offset": [40, 0]])
        #expect(rgba(t, 30, 24).w < 0.05, "old place cleared: \(rgba(t, 30, 24))")
        #expect(rgba(t, 70, 24).w > 0.95, "object moved: \(rgba(t, 70, 24))")

        // A layer mask and a grayscale document work like any retouch target.
        try t.execute("layer.layerMask.revealAll")
        try t.execute("paint.contentAwareMove", ["offset": [-20, 0], "target": "mask"])
        let g = try session(64, 48, 16, "gray")
        try g.execute("select.rect", ["x": 4, "y": 4, "width": 10, "height": 10])
        try g.execute("paint.contentAwareMove", ["offset": [30, 20], "structure": 2, "color": 5])
    }

    @Test func contentAwareMoveSamplesAllLayersOntoAnEmptyLayer() throws {
        let s = try session(128, 64, 8, "rgb")
        try paintLayer(s, Self.withObject(20, 26))
        try s.execute("layer.new.layer")
        try s.execute("select.rect", ["x": 16, "y": 22, "width": 20, "height": 20])
        // Without Sample All Layers the empty layer has nothing to move.
        try s.execute("paint.contentAwareMove", ["offset": [70, 0]])
        #expect(rgba(s, 95, 31).w < 0.01)
        try s.execute("edit.undo")
        try s.execute("paint.contentAwareMove", ["offset": [70, 0], "sampleAllLayers": true])
        #expect(isObject(rgba(s, 95, 31)), "the object is painted onto the empty layer: \(rgba(s, 95, 31))")
        let fill = rgba(s, 25, 31)
        #expect(fill.w > 0.99 && !isObject(fill), "its old place is covered with fill: \(fill)")
        #expect(rgba(s, 2, 2).w < 0.01, "elsewhere the layer stays empty")
    }

    @Test func contentAwareMoveFailsGracefully() throws {
        let s = try session(64, 48, 8, "rgb")
        #expect(!s.isEnabled("paint.contentAwareMove"), "no selection")
        #expect(throws: EngineError.self) { try s.execute("paint.contentAwareMove", ["offset": [10, 0]]) }
        try s.execute("select.rect", ["x": 10, "y": 10, "width": 10, "height": 10])
        #expect(s.isEnabled("paint.contentAwareMove"))
        let bad: [JSONValue] = [
            [:],
            ["offset": [10]],
            ["offset": "far"],
            ["offset": [1e300, 0]],
            ["offset": [-1e300, 1e300]],
            ["offset": [0, 0]],
            ["offset": [0.4, -0.4]],
            ["offset": [10, 0], "mode": "bogus"],
            ["offset": [10, 0], "structure": 0],
            ["offset": [10, 0], "structure": 8],
            ["offset": [10, 0], "structure": "high"],
            ["offset": [10, 0], "color": -1],
            ["offset": [10, 0], "color": 11],
            ["offset": [10, 0], "color": [1]],
            ["offset": [50, 0]],
            ["offset": [0, -30]],
            ["offset": [10, 0], "target": "mask"],
            ["offset": [10, 0], "target": ["channel": 7]],
            ["offset": [10, 0], "layer": 999],
            ["offset": [10, 0], "scaleX": 0],
            ["offset": [10, 0], "scaleY": 0.5],
            ["offset": [10, 0], "scaleX": 1e9],
            ["offset": [10, 0], "scaleX": "big"],
            ["offset": [10, 0], "rotate": 1e300],
            ["offset": [10, 0], "rotate": [45]],
            ["offset": [5000, 0], "scaleX": 200],
            ["offset": [0, 0], "scaleX": 100, "rotate": 360],
        ]
        for p in bad {
            #expect(throws: EngineError.self, "\(p)") { try s.execute("paint.contentAwareMove", p) }
        }
        try s.execute("paint.contentAwareMove", ["offset": [10, 0], "structure": 7.0, "color": .null])
        // Transform On Drop: scaling in place needs no drag; a big patch may reach past the edge.
        try s.execute("paint.contentAwareMove", ["offset": [0, 0], "scaleX": 150, "rotate": -30])
        try s.execute("paint.contentAwareMove", ["offset": [20, 0], "scaleX": -10000, "scaleY": 10000])
    }
}
