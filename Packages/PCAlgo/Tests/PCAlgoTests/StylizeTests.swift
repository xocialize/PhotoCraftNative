// Port of photocraft-algo (crates/algo/src/stylize.rs, tests.rs, tests_mosaic.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Testing
@testable import PCAlgo
import PCFoundation

@Suite struct StylizeBasicTests {
    @Test func mosaicParity() throws {
        var worst: Float = 0
        for c: Float in [0, 1, 1.5, 2, 7, 13, 50] { worst = max(worst, try Parity.checkVariants(Mosaic(cellSize: c))) }
        ParityLog.record("Mosaic", worst)
    }
    @Test func embossParity() throws {
        var worst: Float = 0
        for (a, h, k): (Float, Float, Float) in [(135, 3, 100), (0, 1, 100), (-40, 7, 500), (90, 0, 1), (200, -3, 250)] {
            worst = max(worst, try Parity.checkVariants(Emboss(angle: a, height: h, amount: k)))
        }
        ParityLog.record("Emboss", worst)
    }
    @Test func findEdgesParity() throws { ParityLog.record("FindEdges", try Parity.checkVariants(FindEdges())) }
    @Test func solarizeParity() throws { ParityLog.record("Solarize", try Parity.checkVariants(Solarize())) }
    @Test func invertParity() throws { ParityLog.record("Invert", try Parity.checkVariants(Invert())) }
    @Test func desaturateParity() throws { ParityLog.record("Desaturate", try Parity.checkVariants(Desaturate())) }
}

@Suite struct Stylize2Tests {
    @Test func diffuseParity() throws {
        var worst: Float = 0
        for m in DiffuseMode.allCases { for s: UInt32 in [0, 4, 777] { worst = max(worst, try Parity.checkVariants(Diffuse(mode: m, seed: s))) } }
        ParityLog.record("Diffuse", worst)
    }
    @Test func tilesParity() throws {
        var worst: Float = 0
        for fill in TileFill.allCases {
            for (c, o): (UInt32, Float) in [(10, 10), (4, 20), (1, 99), (99, 1), (3, 40), (0, 0)] {
                worst = max(worst, try Parity.checkVariants(Tiles(count: c, maxOffset: o, fill: fill, foreground: SIMD4(0, 1, 0, 1), background: SIMD4(1, 0.5, 0.25, 0.5), seed: 6)))
            }
        }
        ParityLog.record("Tiles", worst)
    }
    @Test func traceContourParity() throws {
        var worst: Float = 0
        for (l, u): (Float, Bool) in [(128, true), (128, false), (0, true), (255, false), (37.5, true), (-10, false), (400, true)] {
            worst = max(worst, try Parity.checkVariants(TraceContour(level: l, upper: u)))
        }
        ParityLog.record("TraceContour", worst)
    }
}

@Suite struct StylizeWindTests {
    @Test func windParity() throws {
        var worst: Float = 0
        for m in WindMethod.allCases {
            for r in [false, true] {
                for s: UInt32 in [0, 7, .max] { worst = max(worst, try Parity.checkVariants(Wind(method: m, fromRight: r, seed: s))) }
            }
        }
        ParityLog.record("Wind", worst)
    }
}

@Suite struct StylizeExtrudeTests {
    @Test func extrudeParity() throws {
        var worst: Float = 0
        for kind in ExtrudeType.allCases {
            for (size, depth): (Float, Float) in [(2, 0), (2, 255), (3.5, 190), (8, 64), (22, 255), (30, 30), (255, 100)] {
                for flags in [0, 1, 2, 4, 7] {
                    let f = Extrude(kind: kind, size: size, depth: depth, levelBased: flags & 1 != 0, solidFront: flags & 2 != 0,
                                    maskIncomplete: flags & 4 != 0, seed: 17)
                    // Large cells read a halo of hundreds of px; a smaller source (zeros beyond it on
                    // both backends) keeps the comparison quick.
                    worst = max(worst, try StyParity.checkVariants(f, margin: 40))
                }
            }
        }
        ParityLog.record("Extrude", worst)
    }
}

/// Parity over models the standard variants leave out (Lab, CMYK without alpha, multichannel),
/// for filters whose GPU path takes them.
enum StyModes {
    static let extra: [(Int, ColorMode, Bool)] = [(4, .lab, true), (3, .lab, false), (4, .cmyk, false), (3, .multichannel, false), (4, .indexed, true)]

    @discardableResult
    static func check<F: Filter>(_ filter: F, out: PixelRect = PixelRect(x: 3, y: -2, width: 61, height: 47), tol: Float = 1.0 / 255.0,
                                 expectGPU: Set<ColorMode> = [], sourceLocation: SourceLocation = #_sourceLocation) throws -> Float {
        var worst: Float = 0
        let srcRect: PixelRect
        switch filter.halo(bounds: out) {
        case .bounds: srcRect = out
        case .radius(let r): srcRect = out.outset(by: r)
        }
        for (ch, mode, a) in extra {
            let img = TestImage.make(srcRect, channels: ch, alpha: a, seed: 2)
            let ctx = FilterContext(bounds: out, mode: mode, alpha: a)
            guard filter.supportsGPU(ctx, channels: ch) else {
                #expect(!expectGPU.contains(mode), "\(filter.label) should run \(mode) on the GPU", sourceLocation: sourceLocation)
                continue
            }
            if let e = try Parity.check(filter, src: img, out: out, ctx: ctx, tol: tol, sourceLocation: sourceLocation) { worst = max(worst, e) }
        }
        return worst
    }
}

/// `Parity.checkVariants` with the source limited to `margin` px around the output (samples
/// beyond read as 0 on both backends), for filters whose declared halo is very large.
enum StyParity {
    @discardableResult
    static func checkVariants<F: Filter>(_ filter: F, out: PixelRect = PixelRect(x: 3, y: -2, width: 61, height: 47), margin: Int32,
                                         bounds: PixelRect? = nil, tol: Float = 1.0 / 255.0, seed: UInt32 = 1,
                                         sourceLocation: SourceLocation = #_sourceLocation) throws -> Float {
        var worst: Float = 0
        let b = bounds ?? out
        let srcRect = out.outset(by: margin).union(filter.isGlobal(bounds: b) ? b : .empty)
        for (img, ctx0) in TestImage.variants(srcRect, seed: seed) {
            var ctx = ctx0
            ctx.bounds = b
            if !filter.supportsGPU(ctx, channels: img.channels) { continue }
            if let e = try Parity.check(filter, src: img, out: out, ctx: ctx, tol: tol, sourceLocation: sourceLocation) { worst = max(worst, e) }
        }
        return worst
    }
}

@Suite struct StylizeOilTests {
    @Test func oilParity() throws {
        var worst: Float = 0
        for f in [OilPaint(), OilPaint(stylization: 3, cleanliness: 4, scale: 1, bristleDetail: 5, lighting: true, angle: -60, shine: 2),
                  OilPaint(stylization: 0.1, cleanliness: 0, scale: 0.1, bristleDetail: 0, lighting: false, angle: 0, shine: 0),
                  OilPaint(stylization: 10, cleanliness: 10, scale: 10, bristleDetail: 10, lighting: true, angle: 135, shine: 10)] {
            worst = max(worst, try Parity.checkVariants(f))
        }
        ParityLog.record("OilPaint", worst)
    }
}

@Suite struct StylizeShaderTests {
    /// Parity checks pass vacuously without a GPU library: make a compile failure loud.
    @Test func shaderLibraryCompiles() throws {
        _ = try AlgoGPU.shared()
        for k in ["pca_sty_mosaic_rows", "pca_sty_extrude_blocks", "pca_sty_oil_lic", "pca_sty_wind"] { _ = try AlgoGPU.shared().pipeline(k) }
    }
}

@Suite struct StylizeGlowTests {
    @Test func glowingEdgesParity() throws {
        var worst: Float = 0
        for (w, b, s): (Float, Float, Float) in [(2, 6, 5), (1, 0, 1), (14, 20, 15), (0.5, 3, 0)] {
            worst = max(worst, try Parity.checkVariants(GlowingEdges(edgeWidth: w, edgeBrightness: b, smoothness: s)))
        }
        ParityLog.record("GlowingEdges", worst)
    }
}

@Suite struct StylizeModeParityTests {
    @Test func extraModels() throws {
        var worst: Float = 0
        worst = max(worst, try StyModes.check(OilPaint(), expectGPU: [.lab, .cmyk, .multichannel]))
        worst = max(worst, try StyModes.check(OilPaint(stylization: 7, cleanliness: 1, scale: 3, bristleDetail: 9, lighting: true, angle: 30, shine: 8)))
        for m in DiffuseMode.allCases { worst = max(worst, try StyModes.check(Diffuse(mode: m, seed: 9), expectGPU: [.lab])) }
        worst = max(worst, try StyModes.check(Wind(method: .blast, fromRight: false, seed: 3), expectGPU: [.lab]))
        worst = max(worst, try StyModes.check(Facet(), expectGPU: [.lab]))
        worst = max(worst, try StyModes.check(Extrude(kind: .blocks, size: 6, depth: 60, levelBased: true, seed: 2), expectGPU: [.lab]))
        worst = max(worst, try StyModes.check(Extrude(kind: .pyramids, size: 9, depth: 90, levelBased: true, seed: 2), expectGPU: [.lab]))
        worst = max(worst, try StyModes.check(Mosaic(cellSize: 7)))
        worst = max(worst, try StyModes.check(Tiles(count: 4, maxOffset: 30, fill: .foreground, seed: 1)))
        worst = max(worst, try StyModes.check(Pointillize(cellSize: 6, seed: 1, background: SIMD4(0.2, 0.4, 0.9, 1))))
        worst = max(worst, try StyModes.check(ColorHalftone(maxRadius: 5), expectGPU: [.cmyk, .multichannel]))
        worst = max(worst, try StyModes.check(Mezzotint(kind: .mediumStrokes, seed: 4)))
        worst = max(worst, try StyModes.check(TraceContour(level: 100, upper: true)))
        worst = max(worst, try StyModes.check(Crystallize(cellSize: 7, seed: 5)))
        ParityLog.record("ExtraModels", worst)
    }
}
