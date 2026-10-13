// Port of photocraft-algo (crates/algo/src/tests.rs `all_filters`, tests_ext.rs `new_filters`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// The QA catalog: representative instances of every filter type registered in `AnyFilter`
// (photocraft's `all_filters()` / `new_filters()` parameter sets where photocraft has them, typical
// dialog values otherwise), and the Surface-level runner the cross-cutting QA suites share.

import Foundation
import Testing
@testable import PCAlgo
import PCFoundation

enum QA {
    static let R = PixelRect(x0: 0, y0: 0, x1: 40, y1: 30)
    static let white = SIMD4<Float>(1, 1, 1, 1)
    static let black = SIMD4<Float>(0, 0, 0, 1)

    static func fmt(_ s: SampleType, _ mode: ColorMode = .rgb, alpha: Bool = true) -> PixelFormat { PixelFormat(mode: mode, sample: s, alpha: alpha) }

    /// tests.rs `pattern`.
    static func pattern(_ s: SampleType, _ r: PixelRect = R) -> Surface {
        var surf = Surface(format: fmt(s))
        var v: [Float] = []
        v.reserveCapacity(r.area * 4)
        for y in r.y0..<r.y1 {
            for x in r.x0..<r.x1 {
                v += [Float((x * 7 + y * 3) % 64) / 63, Float((x * x + y) % 50) / 49, Float(y % 9) / 8, 1]
            }
        }
        surf.writeRegion(r, v)
        return surf
    }

    /// tests.rs `flat`.
    static func flat(_ s: SampleType, _ r: PixelRect, _ px: [Float], mode: ColorMode = .rgb, alpha: Bool = true) -> Surface {
        var surf = Surface(format: fmt(s, mode, alpha: alpha))
        surf.fill(r, with: px)
        return surf
    }

    /// The pattern converted to another colour model (tests_ext.rs `new_filters_work_in_other_colour_modes`).
    static func pattern(_ s: SampleType, mode: ColorMode, alpha: Bool = true) -> Surface {
        let src = pattern(.f32)
        let f = fmt(s, mode, alpha: alpha)
        let ctx = FilterContext(bounds: R, format: f)
        let rgba = src.readRGBA(R)
        var v: [Float] = []
        for c in rgba { v += ctx.native(c, channels: f.channels) }
        var out = Surface(format: f)
        out.writeRegion(R, v)
        return out
    }

    /// tests.rs `run`: the filter over the content's output area, bounds R.
    static func run(_ s: Surface, _ f: any Filter, on b: Backend = .cpu, tile: Int = 256, selection: Surface? = nil,
                    bounds: PixelRect = R, extent: PixelRect? = nil) throws -> Surface {
        var out = s
        let area = FilterEngine.outputArea(f, content: ResampleKit.contentBounds(s), bounds: bounds)
        try FilterEngine.apply(f, to: &out, area: area, bounds: bounds, selection: selection, extent: extent, on: b, tile: tile)
        return out
    }

    /// `run`, or nil when the GPU path declines this input (`FilterError.gpuUnsupported`; `.auto`
    /// would fall back to the CPU).
    static func tryRun(_ s: Surface, _ f: any Filter, on b: Backend = .cpu, tile: Int = 256, selection: Surface? = nil,
                       bounds: PixelRect = R, extent: PixelRect? = nil) throws -> Surface? {
        do {
            return try run(s, f, on: b, tile: tile, selection: selection, bounds: bounds, extent: extent)
        } catch FilterError.gpuUnsupported where b == .gpu {
            return nil
        }
    }

    /// photocraft's `all_filters()` types, whose CPU results must be bit-identical across tilings
    /// (the second batch, `new_filters()`, allows 1.5/255 for running sums that start with the tile).
    static func exactTiling(_ f: any Filter) -> Bool {
        switch f {
        case is GaussianBlur, is BoxBlur, is MotionBlur, is RadialBlur, is SurfaceBlur, is UnsharpMask, is SmartSharpen, is HighPass, is AddNoise,
             is Median, is DustAndScratches, is Minimum, is Maximum, is Offset, is Mosaic, is Emboss, is FindEdges, is Solarize, is Invert,
             is Desaturate, is Twirl, is Pinch, is Spherize, is Wave, is Ripple, is PolarCoordinates, is BlurPreset, is SharpenPreset, is Despeckle:
            return true
        default: return false
        }
    }

    /// The area `run` writes, plus R.
    static func area(_ f: any Filter, _ s: Surface) -> PixelRect {
        FilterEngine.outputArea(f, content: ResampleKit.contentBounds(s), bounds: R).union(R)
    }

    static var backends: [Backend] { AlgoGPU.isAvailable ? [.cpu, .gpu] : [.cpu] }

    static func maxDiff(_ a: [Float], _ b: [Float]) -> Float {
        var m: Float = 0
        for (x, y) in zip(a, b) { let d = abs(x - y); if d.isNaN { return .infinity }; m = max(m, d) }
        return m
    }

    static func meanDiff(_ a: [Float], _ b: [Float]) -> Float { zip(a, b).map { abs($0 - $1) }.reduce(0, +) / Float(max(a.count, 1)) }

    /// Max premultiplied difference of two RGBA (or n-channel, alpha last) regions.
    static func premulDiff(_ a: [Float], _ b: [Float], channels n: Int, alpha: Bool = true) -> Float {
        var m: Float = 0
        var i = 0
        while i + n <= a.count {
            let aa: Float = alpha ? a[i + n - 1] : 1, ba: Float = alpha ? b[i + n - 1] : 1
            for c in 0..<n {
                let isA = alpha && c == n - 1
                let d = abs((isA ? aa : a[i + c] * aa) - (isA ? ba : b[i + c] * ba))
                if d.isNaN { return .infinity }
                m = max(m, d)
            }
            i += n
        }
        return m
    }

    /// An 8×8 displacement map of one colour (tests_ext.rs `map_image`).
    static func mapImage(_ v: SIMD4<Float>) -> FloatImage {
        FloatImage(rect: PixelRect(x: 0, y: 0, width: 8, height: 8), channels: 4, data: (0..<64).flatMap { _ in [v.x, v.y, v.z, v.w] })
    }

    /// A Camera Raw development touching every panel.
    static var cameraRaw: CameraRaw {
        var c = CameraRaw()
        c.exposure = 0.4; c.contrast = 20; c.highlights = -30; c.shadows = 25; c.clarity = 15; c.vibrance = 20
        c.hslHue[0] = 10; c.gradeShadows = CameraRawWheel(hue: 220, sat: 20, lum: 0); c.vignetteAmount = -20
        return c
    }

    /// Representative instances of every registered filter type: (registry tag, filter).
    static var catalog: [(tag: String, filter: any Filter)] {
        [
            ("gaussianBlur", GaussianBlur(radius: 2.5)), ("gaussianBlur", GaussianBlur(radius: 9)),
            ("boxBlur", BoxBlur(radius: 2)), ("boxBlur", BoxBlur(radius: 6)),
            ("motionBlur", MotionBlur(angle: 30, distance: 7)),
            ("radialBlur", RadialBlur(amount: 20, method: .spin)), ("radialBlur", RadialBlur(amount: 30, method: .zoom, centerX: 0.3, centerY: 0.6)),
            ("surfaceBlur", SurfaceBlur(radius: 3, threshold: 20)),
            ("smartBlur", SmartBlur(radius: 3, threshold: 40, quality: .high, mode: .normal)),
            ("smartBlur", SmartBlur(radius: 3, threshold: 25, quality: .low, mode: .overlayEdge)),
            ("lensBlur", LensBlur(radius: 4, blades: 6, curvature: 20, rotation: 10, brightness: 30, threshold: 200, noise: 5, seed: 9)),
            ("shapeBlur", ShapeBlur(radius: 3, shape: .star)),
            ("average", AverageBlur()),
            ("blurPreset", BlurPreset(.blur)), ("blurPreset", BlurPreset(.blurMore)),
            ("tiltShift", TiltShift(blur: 6, focus: 0.1, transition: 0.2)),
            ("irisBlur", IrisBlur(pins: [IrisPin(blur: 6)])),
            ("fieldBlur", FieldBlur(pins: [FieldPin(x: 0.2, y: 0.2, blur: 0), FieldPin(x: 0.8, y: 0.8, blur: 6)])),
            ("spinBlur", SpinBlur(pins: [SpinPin(blurAngle: 30)])),
            ("pathBlur", PathBlur(paths: [BlurPath(points: [SIMD2(0.1, 0.2), SIMD2(0.9, 0.8)], speed: 8, taper: 30)])),
            ("unsharpMask", UnsharpMask(amount: 150, radius: 1.5, threshold: 2)),
            ("smartSharpen", SmartSharpen(amount: 100, radius: 1, reduceNoise: 20)),
            ("highPass", HighPass(radius: 3)),
            ("sharpenPreset", SharpenPreset(.sharpen)), ("sharpenPreset", SharpenPreset(.sharpenEdges)),
            ("addNoise", AddNoise(amount: 25, distribution: .gaussian, seed: 3)),
            ("median", Median(radius: 2)),
            ("dustAndScratches", DustAndScratches(radius: 2, threshold: 10)),
            ("despeckle", Despeckle()),
            ("reduceNoise", ReduceNoise(strength: 6, preserveDetails: 60, reduceColorNoise: 45, sharpenDetails: 25, removeJpegArtifact: true)),
            ("minimum", Minimum(radius: 1)), ("maximum", Maximum(radius: 2)),
            ("minimum", Minimum(radius: 2.5, preserve: .roundness)), ("maximum", Maximum(radius: 3, preserve: .roundness)),
            ("offset", Offset(horizontal: 7, vertical: -3, undefined: .wrap)),
            ("custom", CustomKernel(kernel: [0, 0, 0, 0, 0, 0, 0, -1, 0, 0, 0, -1, 5, -1, 0, 0, 0, -1, 0, 0, 0, 0, 0, 0, 0], scale: 1, offset: 0)),
            ("twirl", Twirl(angle: 90)), ("pinch", Pinch(amount: 50)), ("spherize", Spherize(amount: -60, mode: .horizontalOnly)),
            ("wave", Wave(generators: 3, wavelengthMin: 5, wavelengthMax: 20, amplitudeMin: 1, amplitudeMax: 4, waveType: .triangle, undefined: .repeat, seed: 9)),
            ("ripple", Ripple(amount: 200, size: .small)),
            ("polarCoordinates", PolarCoordinates(mode: .rectangularToPolar)), ("polarCoordinates", PolarCoordinates(mode: .polarToRectangular)),
            ("displace", Displace(horizontal: 10, vertical: 10, stretch: true, undefined: .wrap, map: mapImage(SIMD4(0.8, 0.3, 0.5, 1)))),
            ("shear", Shear(points: [SIMD2(0, 0), SIMD2(0.5, 0.3), SIMD2(1, 0)], undefined: .repeat)),
            ("zigZag", ZigZag(amount: 50, ridges: 4, style: .pondRipples)),
            ("fibers", Fibers(variance: 16, strength: 4, seed: 8, foreground: black, background: white)),
            ("lensFlare", LensFlare(brightness: 100, centerX: 0.3, centerY: 0.3, lens: .zoom)),
            ("lightingEffects", LightingEffects(lights: [Light()], gloss: 0, metallic: 0, exposure: 0, ambience: 10, texture: .luminance, height: 50, whiteIsHigh: true)),
            ("relight", Relight(angle: 45, elevation: 40, intensity: 40, ambient: 55, warmth: 0, softness: 25)),
            ("clouds", Clouds(seed: 3, documentSize: PixelSize(width: 40, height: 30))),
            ("clouds", Clouds(seed: 5, difference: true, documentSize: PixelSize(width: 40, height: 30))),
            ("hsbHsl", HsbHsl(input: .rgb, output: .hsl)),
            ("colorToAlpha", ColorToAlpha(color: white, transparencyThreshold: 0, opacityThreshold: 1)),
            ("colorToAlpha", ColorToAlpha(color: SIMD4(0.5, 0.25, 0.75, 1), transparencyThreshold: 0.1, opacityThreshold: 0.9)),
            ("deInterlace", DeInterlace(eliminateEven: false, interpolate: true)),
            ("ntscColors", NTSCColors()),
            ("shadowsHighlights", ShadowsHighlights(shadowAmount: 50, shadowRadius: 8, highlightAmount: 30, highlightRadius: 8)),
            ("cameraRaw", CameraRawFilter(settings: cameraRaw)),
            ("replaceColor", ReplaceColor(color: SIMD3(0.8, 0.3, 0.2), fuzziness: 80, hue: 40, saturation: 20, lightness: -10)),
            ("matchColor", MatchColorFilter(options: MatchColor(luminance: 120, intensity: 80, fade: 10),
                                            target: LabStats(mean: SIMD3(50, 5, -3), std: SIMD3(20, 8, 9)),
                                            source: LabStats(mean: SIMD3(60, -10, 12), std: SIMD3(15, 12, 10)))),
            ("hdrToning", HdrToning(radius: 6, strength: 1, gamma: 0.8, exposure: 0.3, detail: 50, saturation: 30)),
            ("hdrToneMap", HDRToneMap(method: .exposureGamma(exposure: 0.5, gamma: 1.2))),
            ("hdrToneMap", HDRToneMap(method: .highlightCompression)),
            ("hdrToneMap", HDRToneMap(method: .equalizeHistogram)),
            ("hdrToneMap", HDRToneMap(method: .localAdaptation(HdrToning(radius: 5)))),
            ("mosaic", Mosaic(cellSize: 6)), ("emboss", Emboss(angle: 135, height: 2, amount: 100)), ("findEdges", FindEdges()),
            ("solarize", Solarize()), ("invert", Invert()), ("desaturate", Desaturate()),
            ("diffuse", Diffuse(mode: .normal, seed: 4)), ("diffuse", Diffuse(mode: .anisotropic, seed: 4)),
            ("extrude", Extrude(kind: .blocks, size: 6, depth: 20, seed: 5)),
            ("extrude", Extrude(kind: .pyramids, size: 6, depth: 30, levelBased: true, maskIncomplete: true, seed: 5)),
            ("oilPaint", OilPaint(stylization: 3, cleanliness: 4, scale: 1, bristleDetail: 5, lighting: true, angle: -60, shine: 2)),
            ("tiles", Tiles(count: 4, maxOffset: 20, fill: .background, foreground: black, background: white, seed: 6)),
            ("traceContour", TraceContour(level: 128, upper: true)),
            ("wind", Wind(method: .blast, fromRight: false, seed: 7)), ("wind", Wind(method: .stagger, fromRight: true, seed: 7)),
            ("glowingEdges", GlowingEdges(edgeWidth: 2, edgeBrightness: 6, smoothness: 5)),
            ("colorHalftone", ColorHalftone(maxRadius: 4, angles: SIMD4(108, 162, 90, 45))),
            ("crystallize", Crystallize(cellSize: 6, seed: 1)), ("facet", Facet()), ("fragment", Fragment()),
            ("mezzotint", Mezzotint(kind: .mediumLines, seed: 2)), ("mezzotint", Mezzotint(kind: .grainyDots, seed: 2)),
            ("pointillize", Pointillize(cellSize: 5, seed: 3, background: white)),
            ("lensCorrection", LensCorrection(profile: Lens.genericProfile(focal35mm: 16), redCyan: -40, vignetteAmount: 30, edge: .edgeExtension)),
            ("lensCorrection", LensCorrection(vertical: -20, angle: 5, scale: 110)),
            ("filterGallery", FilterGallery(GalleryEffect(.dryBrush), GalleryEffect(.glowingEdges))),
        ]
    }

    /// A label that tells catalog entries of one type apart.
    static func name(_ e: (tag: String, filter: any Filter)) -> String {
        let j = (try? JSONEncoder().encode(AnyFilter(e.filter))).map { String(decoding: $0, as: UTF8.self) } ?? ""
        return "\(e.filter.label) \(j.prefix(120))"
    }
}

@Suite struct QACatalogTests {
    /// Every registered type has a catalog entry and every entry is registered under its tag.
    @Test func catalogCoversEveryRegisteredType() {
        let tags = Set(QA.catalog.map(\.tag))
        for r in AnyFilter.registry { #expect(tags.contains(r.tag), "no QA catalog entry for \(r.tag)") }
        for e in QA.catalog { #expect(AnyFilter.tag(of: e.filter) == e.tag, "\(e.filter.label) is registered as \(String(describing: AnyFilter.tag(of: e.filter))), not \(e.tag)") }
    }

    /// Every catalog entry survives the tagged JSON round trip (photocraft `params_serde_roundtrip`,
    /// `new_params_serde_roundtrip`; caller-supplied maps are not serialised).
    @Test func everyFilterRoundTripsThroughTaggedJSON() throws {
        let enc = JSONEncoder()
        enc.outputFormatting = .sortedKeys
        for e in QA.catalog {
            let data = try enc.encode(AnyFilter(e.filter))
            let back = try JSONDecoder().decode(AnyFilter.self, from: data)
            #expect(type(of: back.filter) == type(of: e.filter), "\(e.tag)")
            #expect(try enc.encode(AnyFilter(back.filter)) == data, "\(QA.name(e)) changes through JSON")
        }
    }
}
