// Port of photocraft-algo (crates/algo/src/tests.rs, tests_ext.rs — the Stylize and Pixelate cases), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// photocraft's behaviour tests on 40×30 surfaces, run through the Surface-level engine on the
// CPU and on the GPU.

import Foundation
import Testing
@testable import PCAlgo
import PCFoundation

enum StyFix {
    static let r = PixelRect(x0: 0, y0: 0, x1: 40, y1: 30)
    static let white = SIMD4<Float>(1, 1, 1, 1)
    static let black = SIMD4<Float>(0, 0, 0, 1)

    static func fmt(_ s: SampleType) -> PixelFormat { PixelFormat(mode: .rgb, sample: s, alpha: true) }

    /// tests.rs `pattern`.
    static func pattern(_ s: SampleType, _ r: PixelRect = r) -> Surface {
        var surf = Surface(format: fmt(s))
        var v: [Float] = []
        for y in r.y0..<r.y1 {
            for x in r.x0..<r.x1 {
                v += [Float((x * 7 + y * 3) % 64) / 63, Float((x * x + y) % 50) / 49, Float(y % 9) / 8, 1]
            }
        }
        surf.writeRegion(r, v)
        return surf
    }

    /// tests.rs `flat`.
    static func flat(_ s: SampleType, _ r: PixelRect, _ px: SIMD4<Float>) -> Surface {
        var surf = Surface(format: fmt(s))
        surf.writeRegion(r, [Float]((0..<r.area).flatMap { _ in [px.x, px.y, px.z, px.w] }))
        return surf
    }

    /// tests.rs `run`: the output area of the content, bounds R.
    static func run<F: Filter>(_ s: Surface, _ f: F, _ backend: Backend = .cpu, tile: Int = 2048, selection: Surface? = nil) throws -> Surface {
        var out = s
        let area = FilterEngine.outputArea(f, content: s.contentBounds, bounds: r)
        try FilterEngine.apply(f, to: &out, area: area, bounds: r, selection: selection, on: backend, tile: tile)
        return out
    }

    static var backends: [Backend] { AlgoGPU.isAvailable ? [.cpu, .gpu] : [.cpu] }

    static func maxDiff(_ a: [Float], _ b: [Float]) -> Float { zip(a, b).map { abs($0 - $1) }.max() ?? 0 }
    static func meanDiff(_ a: [Float], _ b: [Float]) -> Float { zip(a, b).map { abs($0 - $1) }.reduce(0, +) / Float(max(a.count, 1)) }

    /// tests_ext.rs `new_filters` (this area's entries) plus tests.rs's Stylize entries and Glowing Edges.
    static var filters: [any Filter] {
        [Mosaic(cellSize: 6), Emboss(angle: 135, height: 2, amount: 100), FindEdges(), Solarize(), Invert(), Desaturate(),
         ColorHalftone(maxRadius: 4), Crystallize(cellSize: 6, seed: 1), Facet(), Fragment(),
         Mezzotint(kind: .mediumLines, seed: 2), Mezzotint(kind: .grainyDots, seed: 2), Pointillize(cellSize: 5, seed: 3, background: white),
         Diffuse(mode: .normal, seed: 4), Diffuse(mode: .anisotropic, seed: 4),
         Extrude(kind: .blocks, size: 6, depth: 20, seed: 5), Extrude(kind: .pyramids, size: 6, depth: 30, levelBased: true, maskIncomplete: true, seed: 5),
         OilPaint(stylization: 3, cleanliness: 4, scale: 1, bristleDetail: 5, lighting: true, angle: -60, shine: 2),
         Tiles(count: 4, maxOffset: 20, fill: .background, foreground: black, background: white, seed: 6),
         TraceContour(level: 128, upper: true), Wind(method: .blast, fromRight: false, seed: 7), Wind(method: .stagger, fromRight: true, seed: 7),
         GlowingEdges()]
    }

    /// tests_ext.rs `thresholdy`: filters compared across depths on average only.
    static func thresholdy(_ f: any Filter) -> Bool {
        if let e = f as? Extrude { return e.levelBased }
        return f is Facet || f is OilPaint || f is Mezzotint || f is TraceContour || f is ColorHalftone || f is Diffuse || f is Wind
    }
}

@Suite struct StylizeBehaviourTests {
    // MARK: tests.rs

    @Test func mosaicCellsAreUniform() throws {
        let s = StyFix.pattern(.f32)
        for be in StyFix.backends {
            let m = try StyFix.run(s, Mosaic(cellSize: 5), be)
            #expect(m.pixel(x: 0, y: 0) == m.pixel(x: 4, y: 4))
            #expect(m.pixel(x: 4, y: 4) != m.pixel(x: 5, y: 4))
        }
    }

    @Test func stylizeBasics() throws {
        let s = StyFix.flat(.f32, StyFix.r, SIMD4(0.8, 0.3, 0.1, 1))
        for be in StyFix.backends {
            let e = try StyFix.run(s, Emboss(angle: 45, height: 3, amount: 100), be).pixel(x: 20, y: 15)
            #expect(abs(e[0] - 0.5) < 1e-5 && abs(e[1] - 0.5) < 1e-5, "\(e)")
            let f = try StyFix.run(s, FindEdges(), be).pixel(x: 20, y: 15)
            #expect(abs(f[0] - 1) < 1e-6)
            let so = try StyFix.run(s, Solarize(), be).pixel(x: 3, y: 3)
            #expect(abs(so[0] - 0.2) < 1e-6 && abs(so[1] - 0.3) < 1e-6)
            let d = try StyFix.run(s, Desaturate(), be).pixel(x: 3, y: 3)
            #expect(abs(d[0] - d[1]) < 1e-6 && abs(d[1] - d[2]) < 1e-6)
        }
    }

    @Test func otherColourModesWork() throws {
        for mode in [ColorMode.grayscale, .cmyk, .lab] {
            let f = PixelFormat(mode: mode, sample: .u8, alpha: true)
            var s = Surface(format: f)
            s.writeRegion(StyFix.r, [Float]((0..<StyFix.r.area).flatMap { _ in [Float](repeating: 0.4, count: f.channels - 1) + [1] }))
            for be in [Backend.cpu, .auto] {
                for p in [Desaturate(), Emboss(angle: 0, height: 1, amount: 100)] as [any Filter] {
                    let out = try StyFix.run(s, p, be)
                    #expect(out.format == f)
                    #expect(out.readRegion(StyFix.r).allSatisfy { $0.isFinite })
                }
            }
        }
    }

    // MARK: tests_ext.rs

    @Test func filtersAreTileIndependent() throws {
        let s = StyFix.pattern(.u8)
        for p in StyFix.filters {
            for be in StyFix.backends {
                let a = try StyFix.run(s, p, be, tile: 256), b = try StyFix.run(s, p, be, tile: 16)
                let area = FilterEngine.outputArea(p, content: s.contentBounds, bounds: StyFix.r).union(StyFix.r)
                let d = StyFix.maxDiff(a.readRegion(area), b.readRegion(area))
                // Running-sum blurs may round differently by one level depending on where a window starts.
                #expect(d <= 1.5 / 255, "\(p.label) \(be) differs between tile sizes by \(d)")
            }
        }
    }

    @Test func filtersChangePixelsAndRespectEmptySelection() throws {
        let s = StyFix.pattern(.u16)
        let none = Surface(format: .gray8)
        for p in StyFix.filters {
            for be in StyFix.backends {
                let out = try StyFix.run(s, p, be)
                #expect(out != s, "\(p.label) did nothing")
                let area = FilterEngine.outputArea(p, content: s.contentBounds, bounds: StyFix.r)
                let masked = try StyFix.run(s, p, be, selection: none)
                #expect(masked.readRegion(area) == s.readRegion(area), "\(p.label) ignored an empty selection")
            }
        }
    }

    @Test func filtersAgreeAcrossBitDepths() throws {
        for p in StyFix.filters {
            for be in StyFix.backends {
                // Clamp float results the way integer storage does, so HDR overshoot does not count.
                let outs = try [SampleType.u8, .u16, .f32].map { st in
                    try StyFix.run(StyFix.pattern(st), p, be).readRegion(StyFix.r).map { min(max($0, 0), 1) }
                }
                for k in 1..<3 {
                    let (mx, mn) = (StyFix.maxDiff(outs[0], outs[k]), StyFix.meanDiff(outs[0], outs[k]))
                    if StyFix.thresholdy(p) {
                        #expect(mn < 0.06, "\(p.label): mean depth difference \(mn)")
                    } else {
                        #expect(mx < 0.06 && mn < 0.01, "\(p.label): depth difference max \(mx) mean \(mn)")
                    }
                }
            }
        }
    }

    @Test func filtersWorkInOtherColourModes() throws {
        let src = StyFix.pattern(.f32)
        let srcFmt = StyFix.fmt(.f32)
        for mode in [ColorMode.grayscale, .cmyk, .lab] {
            let f = PixelFormat(mode: mode, sample: .u8, alpha: true)
            let ctx = FilterContext(bounds: StyFix.r, format: f)
            let srcCtx = FilterContext(bounds: StyFix.r, format: srcFmt)
            var s = Surface(format: f)
            for y in StyFix.r.y0..<StyFix.r.y1 {
                for x in StyFix.r.x0..<StyFix.r.x1 {
                    s.setPixel(x: x, y: y, ctx.native(srcCtx.rgba(src.pixel(x: x, y: y)), channels: f.channels))
                }
            }
            for p in StyFix.filters {
                for be in [Backend.cpu, .auto] {
                    let out = try StyFix.run(s, p, be)
                    #expect(out.format == f)
                    #expect(out.readRegion(StyFix.r).allSatisfy { $0.isFinite }, "\(p.label) \(mode)")
                }
            }
        }
    }

    @Test func flatImagesStayFlat() throws {
        let c = SIMD4<Float>(0.3, 0.55, 0.8, 1)
        let s = StyFix.flat(.f32, StyFix.r, c)
        for p in [Crystallize(cellSize: 6, seed: 1), Facet(),
                  OilPaint(stylization: 3, cleanliness: 4, scale: 1, bristleDetail: 0, lighting: true, angle: -60, shine: 2),
                  Wind(method: .blast, fromRight: false, seed: 0)] as [any Filter] {
            for be in StyFix.backends {
                let px = try StyFix.run(s, p, be).pixel(x: 20, y: 15)
                for k in 0..<4 { #expect(abs(px[k] - c[k]) < 2e-3, "\(p.label) \(be): \(px)") }
            }
        }
    }

    @Test func mezzotintIsBinaryAndTracksBrightness() throws {
        let s = StyFix.flat(.f32, StyFix.r, SIMD4(0.25, 0.5, 0.75, 1))
        for be in StyFix.backends {
            let v = try StyFix.run(s, Mezzotint(kind: .fineDots, seed: 1), be).readRegion(StyFix.r)
            var mean: [Float] = [0, 0, 0]
            for i in 0..<StyFix.r.area {
                for k in 0..<3 {
                    #expect(v[i * 4 + k] == 0 || v[i * 4 + k] == 1)
                    mean[k] += v[i * 4 + k] / 1200
                }
            }
            #expect(abs(mean[0] - 0.25) < 0.06 && abs(mean[1] - 0.5) < 0.06 && abs(mean[2] - 0.75) < 0.06, "\(mean)")
        }
    }

    @Test func halftoneCoversByInk() throws {
        for be in StyFix.backends {
            let w = try StyFix.run(StyFix.flat(.f32, StyFix.r, StyFix.white), ColorHalftone(maxRadius: 4), be)
            #expect(w.readRegion(StyFix.r).allSatisfy { abs($0 - 1) < 1e-6 }, "white paper stays white")
            let b = try StyFix.run(StyFix.flat(.f32, StyFix.r, StyFix.black), ColorHalftone(maxRadius: 4), be).readRegion(StyFix.r)
            let meanB = stride(from: 0, to: b.count, by: 4).map { b[$0] }.reduce(0, +) / 1200
            #expect(meanB < 0.05, "black is fully inked: \(meanB)")
            let g = try StyFix.run(StyFix.flat(.f32, StyFix.r, SIMD4(0.5, 0.5, 0.5, 1)), ColorHalftone(maxRadius: 4), be).readRegion(StyFix.r)
            let meanG = stride(from: 1, to: g.count, by: 4).map { g[$0] }.reduce(0, +) / 1200
            #expect(abs(meanG - 0.5) < 0.12, "mid gray ≈ half coverage: \(meanG)")
        }
    }

    @Test func pointillizeShowsCanvas() throws {
        let s = StyFix.flat(.f32, StyFix.r, SIMD4(0, 0, 1, 1))
        for be in StyFix.backends {
            let v = try StyFix.run(s, Pointillize(cellSize: 10, seed: 3, background: SIMD4(1, 0, 0, 1)), be).readRegion(StyFix.r)
            let px = (0..<StyFix.r.area).map { Array(v[($0 * 4)..<($0 * 4 + 4)]) }
            #expect(px.contains { $0[0] > 0.99 && $0[2] < 0.01 }, "canvas visible between dots")
            #expect(px.contains { $0[2] > 0.9 }, "dots take the image colour")
        }
    }

    @Test func diffuseOnlyMovesPixelsLocally() throws {
        let s = StyFix.pattern(.f32)
        for be in StyFix.backends {
            let out = try StyFix.run(s, Diffuse(mode: .normal, seed: 1), be)
            for y: Int32 in 1..<29 {
                for x: Int32 in 1..<39 {
                    let p = out.pixel(x: x, y: y)
                    let found = (-1...1).contains { dy in (-1...1).contains { dx in s.pixel(x: x + Int32(dx), y: y + Int32(dy)) == p } }
                    #expect(found, "(\(x),\(y))")
                }
            }
            let dark = try StyFix.run(s, Diffuse(mode: .darkenOnly, seed: 1), be)
            let l = { (p: [Float]) in 0.299 * p[0] + 0.587 * p[1] + 0.114 * p[2] }
            for y: Int32 in 1..<29 { for x: Int32 in 1..<39 { #expect(l(dark.pixel(x: x, y: y)) <= l(s.pixel(x: x, y: y)) + 1e-6) } }
        }
    }

    @Test func traceContourDrawsLineAtLevelCrossing() throws {
        var s = StyFix.flat(.f32, StyFix.r, SIMD4(0.2, 0.2, 0.2, 1))
        let right = PixelRect(x0: 20, y0: 0, x1: 40, y1: 30)
        s.writeRegion(right, [Float]((0..<right.area).flatMap { _ in [Float(0.8), 0.8, 0.8, 1] }))
        for be in StyFix.backends {
            let up = try StyFix.run(s, TraceContour(level: 128, upper: true), be)
            #expect(up.pixel(x: 20, y: 10)[0] == 0, "line on the bright side")
            #expect(up.pixel(x: 19, y: 10)[0] == 1)
            #expect(up.pixel(x: 30, y: 10)[0] == 1)
            let lo = try StyFix.run(s, TraceContour(level: 128, upper: false), be)
            #expect(lo.pixel(x: 19, y: 10)[0] == 0, "line on the dark side")
        }
    }

    @Test func traceContourOffCanvasDoesNotFail() throws {
        let s = StyFix.flat(.f32, PixelRect(x0: 100, y0: 100, x1: 120, y1: 120), SIMD4(0.8, 0.8, 0.8, 1))
        for be in StyFix.backends {
            var out = s
            try FilterEngine.apply(TraceContour(level: 128, upper: true), to: &out, area: s.contentBounds, bounds: StyFix.r, on: be, tile: 64)
        }
    }

    @Test func tilesLeaveGapsWithFill() throws {
        let s = StyFix.flat(.f32, StyFix.r, SIMD4(0, 0, 1, 1))
        for be in StyFix.backends {
            let v = try StyFix.run(s, Tiles(count: 3, maxOffset: 40, fill: .foreground, foreground: SIMD4(0, 1, 0, 1), background: StyFix.white, seed: 2), be)
                .readRegion(StyFix.r)
            #expect((0..<StyFix.r.area).contains { v[$0 * 4 + 1] > 0.99 }, "foreground gaps")
            #expect((0..<StyFix.r.area).filter { v[$0 * 4 + 2] > 0.99 }.count > 600, "mostly tiles")
        }
    }

    @Test func extrudeBlocksAndPyramidsShadeCells() throws {
        let s = StyFix.pattern(.f32)
        for be in StyFix.backends {
            let blocks = try StyFix.run(s, Extrude(kind: .blocks, size: 8, depth: 40, solidFront: true, seed: 1), be)
            // A solid front face is uniform: find two equal neighbours somewhere in the middle.
            #expect((5..<35).contains { (x: Int32) in blocks.pixel(x: x, y: 12) == blocks.pixel(x: x + 1, y: 12) })
            let pyr = try StyFix.run(StyFix.flat(.f32, StyFix.r, SIMD4(0.5, 0.5, 0.5, 1)), Extrude(kind: .pyramids, size: 10, depth: 100, seed: 1), be)
            // Light from the top-left: the left face is brighter than the right face.
            #expect(pyr.pixel(x: 11, y: 15)[0] > pyr.pixel(x: 18, y: 15)[0])
        }
    }

    /// Glowing Edges (no photocraft test): flat areas go black, a hard edge glows, and colour
    /// edges keep their channel.
    @Test func glowingEdgesLightEdgesOnly() throws {
        var s = StyFix.flat(.f32, StyFix.r, SIMD4(0.1, 0.1, 0.1, 1))
        let right = PixelRect(x0: 20, y0: 0, x1: 40, y1: 30)
        s.writeRegion(right, [Float]((0..<right.area).flatMap { _ in [Float(0.9), 0.1, 0.1, 1] }))
        for be in StyFix.backends {
            let out = try StyFix.run(s, GlowingEdges(), be)
            #expect(out.pixel(x: 5, y: 15)[0] < 1e-4, "flat area is dark")
            let e = out.pixel(x: 20, y: 15)
            #expect(e[0] > 0.9 && e[1] < 1e-4, "the red edge glows red: \(e)")
            #expect(out.pixel(x: 5, y: 15)[3] == 1)
        }
    }

    @Test func paramsCodableRoundTrip() throws {
        let enc = JSONEncoder(), dec = JSONDecoder()
        let oil = OilPaint(stylization: 3, cleanliness: 4, scale: 1, bristleDetail: 5, lighting: true, angle: -60, shine: 2)
        let j = String(decoding: try enc.encode(oil), as: UTF8.self)
        #expect(j.contains("\"bristleDetail\""))
        #expect(try dec.decode(OilPaint.self, from: enc.encode(oil)) == oil)
        let ex = Extrude(kind: .pyramids, size: 6, depth: 30, levelBased: true, solidFront: false, maskIncomplete: true, seed: 5)
        #expect(String(decoding: try enc.encode(ex), as: UTF8.self).contains("\"pyramids\""))
        #expect(try dec.decode(Extrude.self, from: enc.encode(ex)) == ex)
        #expect(try dec.decode(Mezzotint.self, from: Data(#"{"kind":"mediumStrokes","seed":3}"#.utf8)) == Mezzotint(kind: .mediumStrokes, seed: 3))
        #expect(try dec.decode(Wind.self, from: Data(#"{"method":"blast","fromRight":false,"seed":0}"#.utf8)) == Wind(method: .blast, fromRight: false))
        #expect(try dec.decode(Tiles.self, from: enc.encode(Tiles(fill: .unaltered))).fill == .unaltered)
        #expect(try dec.decode(Diffuse.self, from: Data(#"{"mode":"darkenOnly","seed":1}"#.utf8)).mode == .darkenOnly)
        #expect(try dec.decode(Pointillize.self, from: Data(#"{"cellSize":5,"seed":0,"background":[1,0,0,1]}"#.utf8)).background == SIMD4(1, 0, 0, 1))
        #expect(try dec.decode(ColorHalftone.self, from: Data(#"{"maxRadius":8,"angles":[108,162,90,45]}"#.utf8)) == ColorHalftone())
        #expect(try dec.decode(GlowingEdges.self, from: Data(#"{"edgeWidth":2,"edgeBrightness":6,"smoothness":5}"#.utf8)) == GlowingEdges())
    }

    @Test func halos() {
        let b = StyFix.r
        #expect(Mosaic(cellSize: 10).halo(bounds: b) == .radius(11))
        #expect(Emboss(height: 3).halo(bounds: b) == .radius(5))
        #expect(FindEdges().halo(bounds: b) == .radius(1))
        #expect(Invert().halo(bounds: b) == .radius(0))
        #expect(Tiles().halo(bounds: b) == .bounds)
        #expect(Wind(method: .blast).halo(bounds: b) == .radius(41))
        #expect(Extrude(size: 30, depth: 30).halo(bounds: b) == .radius(100))  // 7.5 + 90 + 1 → 99 + 1
        #expect(ColorHalftone(maxRadius: 8).halo(bounds: b) == .radius(25))
        #expect(Crystallize(cellSize: 10).halo(bounds: b) == .radius(31))
        #expect(Pointillize(cellSize: 5).halo(bounds: b) == .radius(11))
        #expect(Facet().halo(bounds: b) == .radius(4))
        #expect(Fragment().halo(bounds: b) == .radius(5))
        #expect(Mezzotint().halo(bounds: b) == .radius(0))
        #expect(Mosaic(cellSize: .nan).halo(bounds: b) == .radius(2))
        // smoothness 5 → σ 1.55 (radii 1+1+1 → 4); edge width 2 → σ 0.8 (1+0+0 → 2); + 2.
        let smooth: Int = FxUtil.gaussBoxRadii(1.55).reduce(0, +) + 1
        let edge: Int = FxUtil.gaussBoxRadii(0.8).reduce(0, +) + 1
        #expect(GlowingEdges().halo(bounds: b) == .radius(Int32(smooth + edge + 2)))
    }
}
