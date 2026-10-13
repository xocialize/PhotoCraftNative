// Port of photocraft-algo (crates/algo/src/tests.rs, tests_ext.rs: the cross-cutting filter contract), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// photocraft's filter-contract tests run over every registered filter type (the QA catalog):
// tile independence (CPU bit-exact, GPU within float rounding), changing pixels and honouring an
// empty or half selection, agreement across bit depths, other colour models, the canvas edge, and
// photocraft's identity / flat-image cases.

import Foundation
import Testing
@testable import PCAlgo
import PCFoundation

@Suite struct QABehaviourTests {
    /// photocraft `every_filter_is_tile_independent` / `new_filters_are_tile_independent`: the CPU
    /// reference gives the same bytes whatever the tile size.
    @Test func everyRegisteredFilterIsTileIndependentOnTheCPU() throws {
        let s = QA.pattern(.u8)
        for e in QA.catalog {
            let area = QA.area(e.filter, s)
            let a = try QA.run(s, e.filter, tile: 256), b = try QA.run(s, e.filter, tile: 7)
            let d = QA.maxDiff(a.readRegion(area), b.readRegion(area))
            if QA.exactTiling(e.filter) {
                #expect(a.readInterleaved(area) == b.readInterleaved(area), "\(QA.name(e)) differs between tile sizes by \(d)")
            } else {
                // photocraft's own allowance for the second batch (`new_filters_are_tile_independent`).
                #expect(d <= 1.5 / 255, "\(QA.name(e)) differs between tile sizes by \(d)")
            }
        }
    }

    /// The Metal path is tile-independent within float rounding (premultiplied, float surface).
    @Test func everyRegisteredFilterIsTileIndependentOnTheGPU() throws {
        guard AlgoGPU.isAvailable else { return }
        let s8 = QA.pattern(.u8)
        var s = Surface(format: QA.fmt(.f32))
        s.writeRegion(QA.R, s8.readRegion(QA.R))
        for e in QA.catalog {
            let area = QA.area(e.filter, s)
            guard let a = try QA.tryRun(s, e.filter, on: .gpu, tile: 256), let b = try QA.tryRun(s, e.filter, on: .gpu, tile: 7) else { continue }
            let d = QA.premulDiff(a.readRegion(area), b.readRegion(area), channels: 4)
            #expect(d <= 2e-6, "\(QA.name(e)) on the GPU differs between tile sizes by \(d)")
        }
    }

    /// photocraft `every_filter_changes_something_and_respects_zero_selection` and
    /// `new_filters_change_pixels_and_respect_empty_selection`.
    @Test func everyRegisteredFilterChangesPixelsAndRespectsAnEmptySelection() throws {
        let s = QA.pattern(.u16)
        let none = Surface(format: .gray8)
        for e in QA.catalog {
            for b in QA.backends {
                guard let out = try QA.tryRun(s, e.filter, on: b), let masked = try QA.tryRun(s, e.filter, on: b, selection: none) else { continue }
                #expect(out != s, "\(QA.name(e)) on \(b) did nothing")
                let area = FilterEngine.outputArea(e.filter, content: ResampleKit.contentBounds(s), bounds: QA.R)
                #expect(masked.readRegion(area) == s.readRegion(area), "\(QA.name(e)) on \(b) ignored an empty selection")
            }
        }
    }

    /// photocraft `half_selection_mixes_halfway`.
    @Test func halfSelectionMixesHalfway() throws {
        let s = QA.flat(.f32, QA.R, [0.2, 0.4, 0.6, 1])
        let sel = Surface(format: PixelFormat(mode: .grayscale, sample: .f32, alpha: false), defaultPixel: [0.5])
        for b in QA.backends {
            var out = s
            try FilterEngine.apply(Invert(), to: &out, area: QA.R, bounds: QA.R, selection: sel, on: b)
            let p = out.pixel(x: 5, y: 5)
            #expect(abs(p[0] - 0.5) < 1e-5 && abs(p[2] - 0.5) < 1e-5, "\(b): \(p)")
        }
    }

    /// Every filter under a uniform 50 % selection gives the selection mix of the original and the
    /// unselected result (premultiplied where the filter changes alpha).
    @Test func everyRegisteredFilterMixesByAHalfSelection() throws {
        let s8 = QA.pattern(.u8)
        var s = Surface(format: QA.fmt(.f32))
        s.writeRegion(QA.R, s8.readRegion(QA.R))
        let sel = Surface(format: PixelFormat(mode: .grayscale, sample: .f32, alpha: false), defaultPixel: [0.5])
        for e in QA.catalog {
            for b in QA.backends {
                let area = FilterEngine.outputArea(e.filter, content: QA.R, bounds: QA.R)
                guard let fullS = try QA.tryRun(s, e.filter, on: b), let halfS = try QA.tryRun(s, e.filter, on: b, selection: sel) else { continue }
                let full = FloatImage(rect: area, channels: 4, data: fullS.readRegion(area))
                let half = halfS.readRegion(area)
                let want = FilterEngine.mixSelection(original: FloatImage(surface: s, rect: area), filtered: full,
                                                     coverage: [Float](repeating: 0.5, count: area.area), alpha: true)
                let d = QA.premulDiff(half, want.data, channels: 4)
                #expect(d <= 1e-6, "\(QA.name(e)) on \(b): half selection off by \(d)")
            }
        }
    }

    /// Filters whose output steps where a quantised input straddles a threshold (photocraft's
    /// `thresholdy` set, plus this port's other step-like filters): compared on average only.
    static func thresholdy(_ f: any Filter) -> Bool {
        switch f {
        case is Facet, is OilPaint, is Mezzotint, is TraceContour, is SmartBlur, is ColorHalftone, is Diffuse, is Wind, is Median,
             is DustAndScratches, is Minimum, is Maximum, is GlowingEdges, is Despeckle, is ColorToAlpha, is FindEdges, is Solarize,
             is FilterGallery:  // posterising / edge-detecting effects (Dry Brush, Glowing Edges)
            return true
        case let x as Extrude: return x.levelBased
        case let x as HDRToneMap: if case .equalizeHistogram = x.method { return true }; return false
        default: return false
        }
    }

    /// photocraft `new_filters_agree_across_bit_depths`, over every registered filter.
    @Test func everyRegisteredFilterAgreesAcrossBitDepths() throws {
        for e in QA.catalog {
            let outs: [[Float]] = try [SampleType.u8, .u16, .f32].map { st in
                try QA.run(QA.pattern(st), e.filter).readRegion(QA.R).map { min(max($0, 0), 1) }
            }
            for k in 1..<3 {
                let mx = QA.maxDiff(outs[0], outs[k]), mn = QA.meanDiff(outs[0], outs[k])
                if Self.thresholdy(e.filter) {
                    #expect(mn < 0.06, "\(QA.name(e)): mean depth difference \(mn)")
                } else {
                    #expect(mx < 0.06 && mn < 0.01, "\(QA.name(e)): depth difference max \(mx) mean \(mn)")
                }
            }
        }
    }

    /// photocraft `other_colour_modes_work` / `new_filters_work_in_other_colour_modes`, over every
    /// registered filter and both backends.
    @Test func everyRegisteredFilterWorksInOtherColourModes() throws {
        for mode in [ColorMode.grayscale, .cmyk, .lab] {
            let s = QA.pattern(.u8, mode: mode)
            for e in QA.catalog {
                for b in QA.backends {
                    guard let out = try QA.tryRun(s, e.filter, on: b) else { continue }
                    #expect(out.format == s.format)
                    let finite = out.readRegion(QA.R).allSatisfy { $0.isFinite }
                    #expect(finite, "\(QA.name(e)) \(mode) \(b)")
                }
            }
        }
    }

    /// Filters that legitimately change the alpha of an opaque layer.
    static func changesOpaqueAlpha(_ f: any Filter) -> Bool {
        switch f {
        case is ColorToAlpha: return true
        case let x as LensCorrection: return x.edge == .transparency
        default: return false
        }
    }

    /// photocraft `layer_filters_repeat_the_canvas_edge`, over every registered filter: with the
    /// canvas as the extent an opaque layer covering it stays opaque at the edge and doesn't grow.
    @Test func everyRegisteredFilterRepeatsTheCanvasEdge() throws {
        let canvas = QA.R
        for depth in [SampleType.u8, .f32] {
            let s = QA.flat(depth, canvas, [0.2, 0.6, 0.4, 1])
            for e in QA.catalog where !Self.changesOpaqueAlpha(e.filter) {
                for b in QA.backends {
                    guard let out = try QA.tryRun(s, e.filter, on: b, extent: canvas) else { continue }
                    #expect(canvas.contains(ResampleKit.contentBounds(out)), "\(QA.name(e)) \(depth) \(b) grew past the canvas")
                    // Global filters read the bounds as they are (photocraft's shared `Image::read`): a spin
                    // or polar mapping samples beyond the canvas corners. Only neighbourhood filters repeat it.
                    if e.filter.halo(bounds: canvas) == .bounds { continue }
                    for (x, y): (Int32, Int32) in [(0, 0), (39, 0), (0, 29), (39, 29), (20, 0)] {
                        let a = out.pixel(x: x, y: y)[3]
                        #expect(a > 0.999, "\(QA.name(e)) \(depth) \(b): alpha faded at (\(x),\(y)): \(a)")
                    }
                }
            }
        }
    }

    /// photocraft `identities_at_zero_strength` and `distortions_are_identity_at_zero`, plus this
    /// port's zero-strength settings of the other areas.
    @Test func identitiesAtZeroStrength() throws {
        let s = QA.pattern(.u8)
        let cases: [any Filter] = [
            Displace(horizontal: 0, vertical: 0, stretch: true, undefined: .wrap, map: QA.mapImage(SIMD4(0.9, 0.1, 0, 1))),
            Displace(horizontal: 50, vertical: 50, stretch: true, undefined: .wrap, map: nil),
            Shear(points: [SIMD2(0, 0), SIMD2(1, 0)], undefined: .wrap), ZigZag(amount: 0, ridges: 5, style: .aroundCenter),
            HsbHsl(input: .hsb, output: .hsb), Twirl(angle: 0), Pinch(amount: 0), Spherize(amount: 0, mode: .normal), Ripple(amount: 0, size: .large),
            Relight(intensity: 0), LensCorrection(edge: .edgeExtension), MotionBlur(angle: 0, distance: 0), GaussianBlur(radius: 0.01),
            Offset(horizontal: 40, vertical: 30, undefined: .wrap), UnsharpMask(amount: 0, radius: 2, threshold: 0), AddNoise(amount: 0),
            ShadowsHighlights(shadowAmount: 0, highlightAmount: 0, color: 0, midtone: 0, blackClip: 0, whiteClip: 0),
            CameraRawFilter(settings: CameraRaw()), ReplaceColor(color: SIMD3(0.5, 0.5, 0.5)), SmartSharpen(amount: 0),
        ]
        for f in cases {
            for b in QA.backends {
                guard let out = try QA.tryRun(s, f, on: b) else { continue }
                let d = QA.maxDiff(out.readRegion(QA.R), s.readRegion(QA.R))
                #expect(d <= 0.5 / 255, "\(f.label) on \(b) is not identity (\(d))")
            }
        }
    }

    /// photocraft `flat_images_stay_flat` (the cases no area suite covers), on both backends.
    @Test func flatImagesStayFlat() throws {
        let c: [Float] = [0.3, 0.55, 0.8, 1]
        let s = QA.flat(.f32, QA.R, c)
        let filters: [any Filter] = [Crystallize(cellSize: 6, seed: 1), Facet(),
                                     OilPaint(stylization: 3, cleanliness: 4, scale: 1, bristleDetail: 0, lighting: true, angle: -60, shine: 2),
                                     Wind(method: .blast, fromRight: false, seed: 0), DeInterlace(eliminateEven: true, interpolate: true),
                                     GaussianBlur(radius: 4), BoxBlur(radius: 3), MotionBlur(angle: 20, distance: 9), SurfaceBlur(radius: 4, threshold: 30),
                                     Median(radius: 3), AverageBlur(), Despeckle(), IrisBlur(pins: [IrisPin(blur: 6)]), SpinBlur(pins: [SpinPin(blurAngle: 40)]),
                                     PathBlur(paths: [BlurPath(speed: 8)]), FieldBlur(pins: [FieldPin(blur: 4)]), Mosaic(cellSize: 7), Fragment()]
        for f in filters {
            for b in QA.backends {
                let px = try QA.run(s, f, on: b).pixel(x: 20, y: 15)
                for k in 0..<4 { #expect(abs(px[k] - c[k]) < 2e-3, "\(f.label) on \(b): \(px)") }
            }
        }
    }

    /// photocraft `minimum_maximum_spread`.
    @Test func minimumMaximumSpread() throws {
        var s = QA.flat(.f32, QA.R, [0.5, 0.5, 0.5, 1])
        s.setPixel(x: 10, y: 10, [1, 1, 1, 1])
        for b in QA.backends {
            let mx = try QA.run(s, Maximum(radius: 1, preserve: .squareness), on: b)
            #expect(abs(mx.pixel(x: 11, y: 11)[0] - 1) < 1e-6)
            #expect(abs(mx.pixel(x: 12, y: 10)[0] - 0.5) < 1e-6)
            let mn = try QA.run(s, Minimum(radius: 1, preserve: .squareness), on: b)
            #expect(abs(mn.pixel(x: 10, y: 10)[0] - 0.5) < 1e-6)
            // Radius 1 roundness: the four neighbours, not the diagonals.
            var p = QA.flat(.u8, QA.R, [0, 0, 0, 1])
            p.setPixel(x: 20, y: 15, [1, 1, 1, 1])
            let r1 = try QA.run(p, Maximum(radius: 1, preserve: .roundness), on: b)
            #expect(r1.pixel(x: 21, y: 15)[0] == 1 && r1.pixel(x: 21, y: 16)[0] == 0)
        }
    }

    /// photocraft `minimum_maximum_roundness_match_brute_force`.
    @Test func minimumMaximumRoundnessMatchBruteForce() throws {
        let s = QA.pattern(.f32)
        let img = s.readRegion(QA.R)
        func at(_ x: Int32, _ y: Int32, _ c: Int) -> Float? { QA.R.contains(x: x, y: y) ? img[Int(y * 40 + x) * 4 + c] : nil }
        for radius: Float in [1, 1.5, 2.9, 4] {
            let ri = Int32(radius.rounded(.down))
            for max in [false, true] {
                for b in QA.backends {
                    let f: any Filter = max ? Maximum(radius: radius, preserve: .roundness) : Minimum(radius: radius, preserve: .roundness)
                    let got = try QA.run(s, f, on: b)
                    var bad = 0
                    for y in (QA.R.y0 + ri)..<(QA.R.y1 - ri) {
                        for x in (QA.R.x0 + ri)..<(QA.R.x1 - ri) {
                            let px = got.pixel(x: x, y: y)
                            for c in 0..<3 {
                                var want: Float = max ? -.greatestFiniteMagnitude : .greatestFiniteMagnitude
                                for dy in -ri...ri {
                                    for dx in -ri...ri where Float(dx * dx + dy * dy) <= radius * radius {
                                        if let v = at(x + dx, y + dy, c) { want = max ? Swift.max(want, v) : Swift.min(want, v) }
                                    }
                                }
                                if abs(px[c] - want) >= 1e-6 { bad += 1 }
                            }
                        }
                    }
                    #expect(bad == 0, "r \(radius) max \(max) \(b): \(bad) samples differ from the brute-force disc")
                }
            }
        }
    }

    /// photocraft `wind_streaks_downwind_from_edges`.
    @Test func windStreaksDownwindFromEdges() throws {
        var s = QA.flat(.f32, QA.R, [0, 0, 0, 1])
        s.fill(PixelRect(x0: 10, y0: 0, x1: 12, y1: 30), with: [1, 1, 1, 1])
        for b in QA.backends {
            let right = try QA.run(s, Wind(method: .blast, fromRight: false, seed: 1), on: b)
            let leftSide = (Int32(0)..<30).map { right.pixel(x: 8, y: $0)[0] }.reduce(0, +)
            let rightSide = (Int32(0)..<30).map { right.pixel(x: 14, y: $0)[0] }.reduce(0, +)
            #expect(rightSide > leftSide + 0.5, "\(b): \(leftSide) \(rightSide)")
        }
    }

    /// photocraft `oil_paint_smooths_along_strokes`.
    @Test func oilPaintSmoothsAlongStrokes() throws {
        let s = try QA.run(QA.flat(.f32, QA.R, [0.5, 0.5, 0.5, 1]), AddNoise(amount: 20, distribution: .gaussian, seed: 4))
        func variance(_ surf: Surface) -> Float {
            let v = surf.readRegion(PixelRect(x0: 8, y0: 8, x1: 32, y1: 22))
            let x = stride(from: 0, to: v.count, by: 4).map { v[$0] }
            let m = x.reduce(0, +) / Float(x.count)
            return x.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Float(x.count)
        }
        for b in QA.backends {
            let out = try QA.run(s, OilPaint(stylization: 5, cleanliness: 5, scale: 2, bristleDetail: 0, lighting: false, angle: 0, shine: 0), on: b)
            #expect(variance(out) < variance(s) * 0.5, "\(b)")
        }
    }
}
