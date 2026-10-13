// Port of photocraft-algo (crates/algo/src/artistic_fx.rs tests, artistic.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import Testing
@testable import PCAlgo
import PCFoundation

enum GFXFix {
    /// One effect with defaults, with `values` overridden.
    static func effect(_ f: GalleryFilter, _ values: [String: Float] = [:], fg: SIMD4<Float>? = nil, bg: SIMD4<Float>? = nil) -> GalleryEffect {
        var e = GalleryEffect(f)
        for (k, v) in values { e.values[k] = v }
        if let fg { e.foreground = fg }
        if let bg { e.background = bg }
        return e
    }

    /// Every effect at its defaults, then at each range parameter's minimum and maximum (and every
    /// choice), so each code path of every effect meets the GPU.
    static func variations(_ f: GalleryFilter) -> [GalleryEffect] {
        var out = [GalleryEffect(f)]
        for p in f.params {
            switch p.kind {
            case .range(let lo, let hi, _):
                for v in [lo, hi] { var e = GalleryEffect(f); e.set(p.key, v); out.append(e) }
            case .choice(let c):
                for i in 1..<c.count { var e = GalleryEffect(f); e.set(p.key, Float(i)); out.append(e) }
            case .bool:
                var e = GalleryEffect(f); e.set(p.key, 1); out.append(e)
            }
        }
        if f.usesColours {
            out.append(effect(f, fg: SIMD4(0.8, 0.1, 0.3, 1), bg: SIMD4(0.1, 0.5, 0.9, 1)))
        }
        return out
    }

    /// artistic_fx tests `pattern`: 56×40 RGBA, a gradient checkerboard.
    static func pattern(_ st: SampleType) -> Surface {
        var s = Surface(format: PixelFormat(mode: .rgb, sample: st, alpha: true))
        for y: Int32 in 0..<40 {
            for x: Int32 in 0..<56 {
                let v = Float((x * 7 + y * 3) % 23) / 22
                let px: [Float] = (x / 9 + y / 7) % 2 == 0 ? [v, 0.3, 1 - v, 1] : [0.9, v * 0.5, 0.2, 1]
                s.setPixel(x: x, y: y, px)
            }
        }
        return s
    }
}

@Suite struct GalleryFXParityTests {
    @Test func shaderLibraryCompiles() throws {
        for k in ["pca_gfx_load", "pca_gfx_line_ff", "pca_gfx_fx_coloredPencil", "pca_gfx_fx_stainedGlass", "pca_gfx_fx_grain"] {
            _ = try AlgoGPU.shared().pipeline(k)
        }
    }

    /// Parity of every effect at its defaults and parameter extremes over the standard variants
    /// (CMYK runs on the CPU: the effects work on sRGB). Each effect records its worst error.
    @Test(arguments: GalleryFilter.allCases)
    func effectParity(_ f: GalleryFilter) throws {
        var worst: Float = 0
        for e in GFXFix.variations(f) {
            worst = max(worst, try Parity.checkVariants(FilterGallery(e), out: PixelRect(x: 3, y: -2, width: 37, height: 29)))
        }
        ParityLog.record("Gallery." + f.key, worst)
    }

    /// Stacks run effects in order on one window.
    @Test func stackParity() throws {
        let stacks: [[GalleryEffect]] = [
            [GalleryEffect(.dryBrush), GalleryEffect(.texturizer)],
            [GalleryEffect(.glowingEdges), GalleryEffect(.crosshatch), GalleryEffect(.grain)],
            [GalleryEffect(.oceanRipple), GalleryEffect(.stainedGlass), GalleryEffect(.notePaper)],
        ]
        var worst: Float = 0
        for s in stacks { worst = max(worst, try Parity.checkVariants(FilterGallery(effects: s), out: PixelRect(x: 3, y: -2, width: 37, height: 29))) }
        ParityLog.record("Gallery.stacks", worst)
    }

    /// Glowing Edges inside the gallery gives the standalone filter's numbers on both backends.
    @Test func glowingEdgesMatchesStandalone() throws {
        let out = PixelRect(x: 3, y: -2, width: 45, height: 33)
        for (w, b, s): (Float, Float, Float) in [(2, 6, 5), (1, 0, 1), (14, 20, 15)] {
            let standalone = GlowingEdges(edgeWidth: w, edgeBrightness: b, smoothness: s)
            let gallery = FilterGallery(GFXFix.effect(.glowingEdges, ["edgeWidth": w, "edgeBrightness": b, "smoothness": s]))
            #expect(standalone.halo(bounds: out) == gallery.halo(bounds: out))
            guard case .radius(let r) = gallery.halo(bounds: out) else { continue }
            for (img, ctx0) in TestImage.variants(out.outset(by: r)) where ctx0.mode != .cmyk {
                var ctx = ctx0
                ctx.bounds = out
                for be in AlgoGPU.isAvailable ? [Backend.cpu, .gpu] : [.cpu] {
                    let a = try FilterEngine.apply(standalone, to: img, output: out, context: ctx, on: be)
                    let g = try FilterEngine.apply(gallery, to: img, output: out, context: ctx, on: be)
                    #expect(a.data == g.data, "\(ctx.mode) \(img.channels)ch \(be)")
                }
            }
        }
    }
}

@Suite struct GalleryFXBehaviourTests {
    /// photocraft `every_effect_changes_pixels_and_is_tile_independent`.
    @Test func everyEffectChangesPixelsAndIsTileIndependent() throws {
        let b = PixelRect(x0: 0, y0: 0, x1: 56, y1: 40)
        for st in [SampleType.u8, .u16, .f32] {
            let s = GFXFix.pattern(st)
            let before = s.readRegion(b)
            for f in GalleryFilter.allCases {
                let fp = FilterGallery(GalleryEffect(f))
                for be in AlgoGPU.isAvailable ? [Backend.cpu, .gpu] : [.cpu] {
                    var a = s
                    try FilterEngine.apply(fp, to: &a, area: b, bounds: b, extent: b, on: be, tile: 256)
                    let av = a.readRegion(b)
                    #expect(av != before, "\(f.key) @\(st) \(be) changed nothing")
                    #expect(av.allSatisfy { $0.isFinite }, "\(f.key)")
                    if st == .f32 {
                        var t = s
                        try FilterEngine.apply(fp, to: &t, area: b, bounds: b, extent: b, on: be, tile: 16)
                        let worst = zip(av, t.readRegion(b)).map { abs($0 - $1) }.max() ?? 0
                        #expect(worst < 1e-3, "\(f.key) \(be) differs across tilings by \(worst)")
                    }
                }
            }
        }
    }

    /// photocraft `rough_pastels_and_angled_strokes_respond_to_every_slider`.
    @Test func roughPastelsAndAngledStrokesRespondToEverySlider() throws {
        let b = PixelRect(x0: 0, y0: 0, x1: 56, y1: 40)
        let s = GFXFix.pattern(.f32)
        func run(_ e: GalleryEffect, _ tile: Int) throws -> [Float] {
            var a = s
            try FilterEngine.apply(FilterGallery(e), to: &a, area: b, bounds: b, extent: b, on: .cpu, tile: tile)
            return a.readRegion(b)
        }
        for f in [GalleryFilter.roughPastels, .angledStrokes] {
            let base = try run(GalleryEffect(f), 256)
            for p in f.params {
                guard case .range(let lo, let hi, _) = p.kind else { continue }
                for v in [lo, hi] {
                    var e = GalleryEffect(f)
                    e.set(p.key, v)
                    let a = try run(e, 256)
                    #expect(a != base, "\(f.key) \(p.key) = \(v) changed nothing")
                    let worst = zip(a, try run(e, 16)).map { abs($0 - $1) }.max() ?? 0
                    #expect(worst < 1e-3, "\(f.key) \(p.key) = \(v) differs across tilings by \(worst)")
                }
            }
        }
    }

    /// photocraft `params_parse_and_clamp`.
    @Test func paramsParseAndClamp() {
        for f in GalleryFilter.allCases {
            #expect(!f.params.isEmpty, "\(f.key)")
            #expect(GalleryFilter.from(key: f.key) == f)
            #expect(GalleryFilter.from(key: f.commandID) == f)
            #expect(GalleryFilter.from(key: f.name) == f)
            #expect(GalleryFilter.categories.contains(f.category))
        }
        #expect(GalleryFilter.allCases.count == 47)
        var e = GalleryEffect(.texturizer)
        #expect(e.choice("texture") == "canvas")
        #expect(e.choice("light") == "top")
        let set = e.setChoice("texture", "brick")
        #expect(set)
        #expect(e.choice("texture") == "brick")
        e.set("relief", 500)
        #expect(e.get("relief") == 50)
        let bad = e.setChoice("texture", "velvet")
        #expect(!bad)
        let neon = GalleryFilter.neonGlow.params.map(\.key)
        #expect(neon == ["glowSize", "glowBrightness"], "json colours are not parameters")
        #expect(GalleryEffect(.neonGlow).get("glowSize") == 5)
        #expect(GalleryFilter.coloredPencil.usesColours && GalleryFilter.neonGlow.usesColours && !GalleryFilter.chrome.usesColours)
    }

    /// photocraft's serde shape: `{"filter":"coloredPencil","values":{…},"foreground":[…],…}`, with
    /// missing colours and values defaulting.
    @Test func codable() throws {
        let enc = JSONEncoder(), dec = JSONDecoder()
        let g = FilterGallery(effects: [GalleryEffect(.coloredPencil), GFXFix.effect(.neonGlow, ["glowSize": -3])])
        #expect(try dec.decode(FilterGallery.self, from: enc.encode(g)) == g)
        let e = try dec.decode(GalleryEffect.self, from: Data(#"{"filter":"stainedGlass","values":{"cellSize":20}}"#.utf8))
        #expect(e.filter == .stainedGlass && e.get("cellSize") == 20 && e.get("borderThickness") == 4)
        #expect(e.foreground == SIMD4(0, 0, 0, 1) && e.background == SIMD4(1, 1, 1, 1) && e.color == GalleryEffect.neonDefault)
        let json = String(decoding: try enc.encode(GalleryEffect(.sumiE)), as: UTF8.self)
        #expect(json.contains("\"filter\":\"sumiE\"") && json.contains("\"strokeWidth\""))
    }

    @Test func labelsAndHalos() {
        let b = PixelRect(x: 0, y: 0, width: 40, height: 30)
        #expect(FilterGallery(GalleryEffect(.sumiE)).label == "Sumi-e")
        #expect(FilterGallery(effects: [GalleryEffect(.sumiE), GalleryEffect(.grain)]).label == "Filter Gallery")
        #expect(FilterGallery(GalleryEffect(.coloredPencil)).halo(bounds: b) == .radius(2))
        #expect(FilterGallery(GalleryEffect(.darkStrokes)).halo(bounds: b) == .radius(9))
        #expect(FilterGallery(effects: [GalleryEffect(.darkStrokes), GalleryEffect(.coloredPencil), GalleryEffect(.grain)]).halo(bounds: b) == .radius(11))
        // Smudge Stick: (2 · 1.5) as i32 + 2.
        #expect(FilterGallery(GalleryEffect(.smudgeStick)).halo(bounds: b) == .radius(5))
        // Stained Glass: ceil((10 · 1.6 + 1) · 2.5) + 2.
        #expect(FilterGallery(GalleryEffect(.stainedGlass)).halo(bounds: b) == .radius(45))
    }
}

@Suite struct GalleryFXModelTests {
    /// Effects that read the reference bounds (Halftone Pattern's circles, Stained Glass's light)
    /// with bounds larger than the output.
    @Test func boundsDependentParity() throws {
        let out = PixelRect(x: 3, y: -2, width: 37, height: 29)
        let bounds = PixelRect(x: -40, y: -30, width: 150, height: 90)
        var e = GalleryEffect(.halftonePattern)
        e.setChoice("patternType", "circle")
        var worst: Float = 0
        for f in [FilterGallery(e), FilterGallery(GalleryEffect(.stainedGlass))] {
            guard case .radius(let r) = f.halo(bounds: bounds) else { continue }
            for (img, ctx0) in TestImage.variants(out.outset(by: r)) where ctx0.mode != .cmyk {
                var ctx = ctx0
                ctx.bounds = bounds
                if let err = try Parity.check(f, src: img, out: out, ctx: ctx) { worst = max(worst, err) }
            }
        }
        ParityLog.record("Gallery.bounds", worst)
    }

    /// CMYK and Lab work on an sRGB copy (the colour conversions), so the engine runs them on the
    /// GPU through its sRGB round trip (`rgbaEquivalent`); the result keeps the format and alpha.
    @Test func otherModelsRunOnTheCPU() throws {
        let out = PixelRect(x: 0, y: 0, width: 24, height: 18)
        let f = FilterGallery(effects: [GalleryEffect(.watercolor), GalleryEffect(.grain)])
        for (ch, mode) in [(5, ColorMode.cmyk), (4, .lab)] {
            let ctx = FilterContext(bounds: out, mode: mode, alpha: true)
            #expect(FilterEngine.runsOnGPU(f, channels: ch, context: ctx) == AlgoGPU.isAvailable)
            guard case .radius(let r) = f.halo(bounds: out) else { continue }
            let img = TestImage.make(out.outset(by: r), channels: ch, alpha: true)
            let res = try FilterEngine.apply(f, to: img, output: out, context: ctx, on: .auto)
            #expect(res.channels == ch && res.data.allSatisfy { $0.isFinite })
            for i in 0..<out.area { #expect(res.data[i * ch + ch - 1] == img.crop(out).data[i * ch + ch - 1], "alpha kept") }
        }
    }
}
