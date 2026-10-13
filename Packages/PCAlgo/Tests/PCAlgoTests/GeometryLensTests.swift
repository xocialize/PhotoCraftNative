// Port of photocraft-algo (crates/algo/src/lens.rs tests, lens/shared_sample_tests.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import Testing
@testable import PCAlgo
import PCFoundation

/// Shared helpers of the Geometry-area tests.
enum GEO {
    /// CPU and GPU of `run` over the standard channel variants; the worst premultiplied
    /// difference (nil without Metal).
    static func variants(_ rect: PixelRect, seed: UInt32 = 1, _ run: (FloatImage, FilterContext, Backend) throws -> FloatImage) throws -> Float? {
        guard AlgoGPU.isAvailable else { return nil }
        var worst: Float = 0
        for (img, ctx) in TestImage.variants(rect, seed: seed) {
            let c = try run(img, ctx, .cpu), g = try run(img, ctx, .gpu)
            #expect(c.rect == g.rect && c.channels == g.channels, "\(ctx.mode) \(img.channels)ch")
            if c.rect != g.rect || c.channels != g.channels { return .infinity }
            worst = max(worst, Parity.maxError(c, g, alpha: ctx.alpha || c.channels > img.channels))
        }
        return worst
    }

    static func maxDiff(_ a: [Float], _ b: [Float]) -> Float { zip(a, b).map { abs($0 - $1) }.max() ?? 0 }
}

@Suite struct GeometryLensTests {
    static func gridSurface(_ fmt: PixelFormat, _ w: Int32, _ h: Int32) -> Surface {
        var s = Surface(format: fmt)
        let ctx = FilterContext(bounds: PixelRect(x0: 0, y0: 0, x1: w, y1: h), format: fmt)
        var data: [Float] = []
        for y in 0..<h {
            for x in 0..<w {
                let v: Float = x % 16 < 2 || y % 16 < 2 ? 0.9 : 0.3
                data += ctx.native(SIMD4(v, v * 0.8, v * 0.6, 1), channels: fmt.channels)
            }
        }
        s.writeRegion(PixelRect(x0: 0, y0: 0, x1: w, y1: h), data)
        return s
    }

    @Test(arguments: [Backend.cpu, .gpu])
    func identityIsLosslessAtAllDepths(_ backend: Backend) {
        if backend == .gpu && !AlgoGPU.isAvailable { return }
        for sample in [SampleType.u8, .u16, .f32] {
            let fmt = PixelFormat(mode: .rgb, sample: sample, alpha: true)
            let s = Self.gridSurface(fmt, 96, 64)
            let r = PixelRect(x0: 0, y0: 0, x1: 96, y1: 64)
            let out = Lens.correct(s, frame: r, LensCorrection(), on: backend)
            let err = GEO.maxDiff(s.readRegion(r), out.readRegion(r))
            #expect(err < 2.0 / 255.0, "\(sample): \(err)")
        }
    }

    @Test(arguments: [Backend.cpu, .gpu])
    func distortionRoundTripAndEdges(_ backend: Backend) {
        if backend == .gpu && !AlgoGPU.isAvailable { return }
        let frame = PixelRect(x0: 0, y0: 0, x1: 200, y1: 100)
        let m = LensMap(LensCorrection(distortion: 50), frame: frame)
        let s = m.sample(100, 50)!
        #expect(abs(s.p.x - 100) < 1e-9 && abs(s.p.y - 50) < 1e-9)
        // Positive Remove Distortion samples corners closer to the centre.
        let c = m.sample(0, 0)!
        #expect(c.p.x > 5 && c.p.y > 2, "\(c)")
        // Transparency leaves the uncovered corners clear; extension and colour fill them.
        let src = Self.gridSurface(PixelFormat(mode: .rgb, sample: .u8, alpha: false), 200, 100)
        let neg = LensCorrection(distortion: -60)
        let t = Lens.correct(src, frame: frame, neg, on: backend)
        #expect(t.format.alpha)
        #expect(t.pixel(x: 0, y: 0)[3] < 0.01 && t.pixel(x: 100, y: 50)[3] > 0.99)
        var ext = neg
        ext.edge = .edgeExtension
        #expect(!Lens.correct(src, frame: frame, ext, on: backend).format.alpha)
        var colour = neg
        colour.edge = .color(SIMD4(1, 0, 0, 1))
        let p = Lens.correct(src, frame: frame, colour, on: backend).pixel(x: 0, y: 0)
        #expect(p[0] > 0.99 && p[1] < 0.01, "\(p)")
    }

    @Test func vignetteCAPerspectiveAndStraighten() {
        let frame = PixelRect(x0: 0, y0: 0, x1: 300, y1: 200)
        let m = LensMap(LensCorrection(vignetteAmount: 100), frame: frame)
        #expect(abs(m.sample(150, 100)!.gain - 1) < 1e-6)
        #expect(m.sample(1, 1)!.gain > 2)
        #expect(LensMap(LensCorrection(vignetteAmount: -100), frame: frame).sample(1, 1)!.gain < 0.5)
        // Lateral CA scales red outward relative to green.
        let ca = LensMap(LensCorrection(redCyan: -100), frame: frame).sample(10, 10)!
        #expect(ca.pr.x < ca.p.x)
        // Vertical perspective −: the top edge samples a narrower source span.
        let v = LensMap(LensCorrection(vertical: -50), frame: frame)
        let tl = v.sample(0, 0)!.p, tr = v.sample(300, 0)!.p, bl = v.sample(0, 200)!.p, br = v.sample(300, 200)!.p
        #expect(tr.x - tl.x < br.x - bl.x)
        // Straighten a line tilted by 5° → −5° correction, and Auto Scale hides the corners.
        let a = Lens.straightenAngle(SIMD2(0, 0), SIMD2(100, 100 * tan(5 * Double.pi / 180)))
        #expect(abs(a + 5) < 1e-9, "\(a)")
        #expect(abs(Lens.straightenAngle(SIMD2(0, 0), SIMD2(3, 100)) - 1.718) < 0.01)
        let lc = LensCorrection(angle: 5)
        let s = Lens.autoScale(lc, frame: frame)
        #expect(s > 105 && s < 130, "\(s)")
        var l2 = lc
        l2.scale = s
        #expect((0.0...300.0).contains(LensMap(l2, frame: frame).sample(0, 0)!.p.x))
    }

    @Test(arguments: [Backend.cpu, .gpu])
    func genericProfilesAndCMYK(_ backend: Backend) {
        if backend == .gpu && !AlgoGPU.isAvailable { return }
        let wide = Lens.genericProfile(focal35mm: 16), tele = Lens.genericProfile(focal35mm: 135)
        #expect(wide.k1 < -0.05 && tele.k1 > 0 && wide.vignette[0] < tele.vignette[0])
        let mid = Lens.genericProfile(focal35mm: 30)
        #expect(mid.k1 < -0.025 && mid.k1 > -0.06)
        #expect(wide.name == "Generic Lens (16 mm equivalent)")
        // CMYK vignette lightening reduces ink.
        var s = Surface(format: PixelFormat(mode: .cmyk, sample: .u8, alpha: false))
        s.fill(PixelRect(x0: 0, y0: 0, x1: 40, y1: 40), with: [0.5, 0.5, 0.5, 0.5])
        let out = Lens.correct(s, frame: PixelRect(x0: 0, y0: 0, x1: 40, y1: 40), LensCorrection(vignetteAmount: 100, edge: .edgeExtension), on: backend)
        #expect(out.pixel(x: 0, y: 0)[0] < 0.4 && abs(out.pixel(x: 20, y: 20)[0] - 0.5) < 0.02, "\(out.pixel(x: 0, y: 0))")
    }

    /// photocraft's `remap_impl` per channel, transcribed directly (its unshared `bicubic` path),
    /// for one image layout: the reference `remapTiles` must match bit for bit (photocraft's
    /// `shared_interpolation_matches_original_at_all_depths_and_edges`).
    static func directRemap(_ img: FloatImage, ctx: FilterContext, srcAlpha: Bool, frame: PixelRect, out: PixelRect, edge: LensEdgeMode,
                            clip: Bool, map: (Double, Double) -> LensSample?) -> FloatImage {
        let n = img.channels, cc = ctx.colorChannels(n)
        let rgb = (ctx.mode == .rgb || ctx.mode == .indexed) && cc == 3, sub = ctx.mode == .cmyk, lab = ctx.mode == .lab
        let edgePx: [Float]
        if case .color(let c) = edge { edgePx = ctx.native(c, channels: n) } else { edgePx = [Float](repeating: 0, count: n) }
        var res = FloatImage(rect: out, channels: n)
        var ty = out.y0
        while ty < out.y1 {
            var tx = out.x0
            while tx < out.x1 {
                let t = PixelRect(x0: tx, y0: ty, x1: min(tx + 128, out.x1), y1: min(ty + 128, out.y1))
                let tw = t.width
                let samples = (0..<t.area).map { map(Double(t.x0) + Double($0 % tw) + 0.5, Double(t.y0) + Double($0 / tw) + 0.5) }
                var (bx0, by0, bx1, by1) = (Double.greatestFiniteMagnitude, Double.greatestFiniteMagnitude, -Double.greatestFiniteMagnitude, -Double.greatestFiniteMagnitude)
                for case let s? in samples { for p in [s.p, s.pr, s.pb] { bx0 = fmin(bx0, p.x); by0 = fmin(by0, p.y); bx1 = fmax(bx1, p.x); by1 = fmax(by1, p.y) } }
                func clX(_ v: Double) -> Int32 { min(max(Int32(v), frame.x0), frame.x1) }
                func clY(_ v: Double) -> Int32 { min(max(Int32(v), frame.y0), frame.y1) }
                let win = bx0 > bx1 ? PixelRect.empty : PixelRect(x0: clX(bx0.rounded(.down) - 3), y0: clY(by0.rounded(.down) - 3), x1: clX(bx1.rounded(.up) + 4), y1: clY(by1.rounded(.up) + 4))
                var buf = win.isEmpty ? [] : img.crop(win).data
                if srcAlpha { for i in stride(from: 0, to: buf.count, by: n) { for c in 0..<(n - 1) { buf[i + c] *= buf[i + n - 1] } } }
                let (fx0, fy0, fx1, fy1) = (Double(frame.x0), Double(frame.y0), Double(frame.x1), Double(frame.y1))
                func bicubic(_ c: Int, _ p: SIMD2<Double>) -> Float {
                    let x = min(max(p.x - 0.5, fx0), fx1 - 1), y = min(max(p.y - 0.5, fy0), fy1 - 1)
                    let xi = x.rounded(.down), yi = y.rounded(.down)
                    let wx = GeometryKit.catmullRom(Float(x - xi)), wy = GeometryKit.catmullRom(Float(y - yi))
                    var acc: Float = 0
                    for j in 0..<4 {
                        let yy = Int(min(max(Int32(yi) + Int32(j) - 1, win.y0), win.y1 - 1) - win.y0)
                        for i in 0..<4 {
                            let xx = Int(min(max(Int32(xi) + Int32(i) - 1, win.x0), win.x1 - 1) - win.x0)
                            acc += wx[i] * wy[j] * buf[(yy * win.width + xx) * n + c]
                        }
                    }
                    return acc
                }
                for (i, s0) in samples.enumerated() {
                    let o = res.index(x: t.x0 + Int32(i % tw), y: t.y0 + Int32(i / tw))
                    guard let s = s0, !win.isEmpty else { for c in 0..<n { res.data[o + c] = edgePx[c] }; continue }
                    let inside: Float = edge == .edgeExtension ? 1 : Float(min(max(min(s.p.x - fx0, fx1 - s.p.x) + 0.5, 0), 1) * min(max(min(s.p.y - fy0, fy1 - s.p.y) + 0.5, 0), 1))
                    let alpha: Float = srcAlpha ? min(max(bicubic(n - 1, s.p), 0), 1) : 1
                    var col = [Float](repeating: 0, count: cc)
                    for c in 0..<cc {
                        let p = rgb && c == 0 ? s.pr : (rgb && c == 2 ? s.pb : s.p)
                        let pm = bicubic(c, p)
                        let st = srcAlpha ? (alpha > 1e-6 ? pm / alpha : 0) : pm
                        var v = sub ? 1 - (1 - st) * s.gain : (lab ? (c == 0 ? st * s.gain : st) : st * s.gain)
                        if clip { v = min(max(v, 0), 1) }
                        col[c] = v
                    }
                    if case .color = edge, inside < 1 {
                        let ea: Float = ctx.alpha ? edgePx[n - 1] : 1
                        let oa = alpha * inside + ea * (1 - inside)
                        for c in 0..<cc {
                            let mixed = col[c] * alpha * inside + edgePx[c] * ea * (1 - inside)
                            res.data[o + c] = oa > 1e-6 ? mixed / oa : 0
                        }
                        if ctx.alpha { res.data[o + n - 1] = oa }
                    } else {
                        for c in 0..<cc { res.data[o + c] = col[c] }
                        if ctx.alpha { res.data[o + n - 1] = alpha * inside }
                    }
                }
                tx += 128
            }
            ty += 128
        }
        return res
    }

    @Test func remapMatchesADirectTranscriptionAtAllModesAndEdges() {
        let bounds = PixelRect(x0: -13, y0: -9, x1: 39, y1: 26)
        for mode in [ColorMode.rgb, .grayscale, .cmyk, .lab, .bitmap, .duotone, .indexed, .multichannel] {
            for clip in [false, true] {
                for alpha in [false, true] {
                    let fmt = PixelFormat(mode: mode, sample: .f32, alpha: alpha)
                    let n = fmt.channels
                    let data: [Float] = (0..<(bounds.area * n)).map { $0 % 17 == 0 ? 0 : Float(($0 * 103 + $0 / n * 71) % 65536) / 65535 }
                    let img = FloatImage(rect: bounds, channels: n, data: data)
                    for edge in [LensEdgeMode.transparency, .edgeExtension, .color(SIMD4(0.2, 0.5, 0.7, 0.4))] {
                        for ca in [false, true] {
                            let map: (Double, Double) -> LensSample? = { x, y in
                                if (Int32(x) + Int32(y)) % 13 == 0 { return nil }
                                let p = SIMD2(x * 0.83 - 3.7, y * 1.14 + 1.3)
                                return LensSample(p: p, pr: ca ? SIMD2(p.x - 0.9, p.y + 0.3) : p, pb: ca ? SIMD2(p.x + 0.7, p.y - 0.4) : p, gain: 1.17)
                            }
                            let out = bounds.outset(by: 3)
                            let needsAlpha = edge == .transparency && !alpha
                            let src = needsAlpha ? GeometryKit.appendAlpha(img) : img
                            var ctx = FilterContext(bounds: bounds, format: fmt)
                            ctx.alpha = alpha || needsAlpha
                            let a = Lens.remap(img, frame: bounds, outArea: out, edge: edge, context: FilterContext(bounds: bounds, format: fmt),
                                               storage: clip ? .u16 : .f32, map: map)
                            let b = Self.directRemap(src, ctx: ctx, srcAlpha: alpha, frame: bounds, out: out, edge: edge, clip: clip, map: map)
                            #expect(a.data.map(\.bitPattern) == b.data.map(\.bitPattern), "\(mode) clip \(clip) alpha \(alpha) edge \(edge) ca \(ca)")
                        }
                    }
                }
            }
        }
    }

    @Test func codableMatchesPhotocraft() throws {
        let json = #"{"distortion":20,"edge":{"color":[1,0,0,1]},"profile":{"name":"x","k1":0.1,"k2":0,"p1":0,"p2":0,"vignette":[0,0,0],"ca_red":0.001,"ca_blue":0}}"#
        let lc = try JSONDecoder().decode(LensCorrection.self, from: Data(json.utf8))
        #expect(lc.distortion == 20 && lc.scale == 100 && lc.vignetteMidpoint == 50 && lc.correctCa && lc.edge == .color(SIMD4(1, 0, 0, 1)))
        #expect(lc.profile?.caRed == 0.001)
        let back = try JSONDecoder().decode(LensCorrection.self, from: try JSONEncoder().encode(lc))
        #expect(back == lc)
        #expect(try JSONDecoder().decode(LensEdgeMode.self, from: Data(#""extension""#.utf8)) == .edgeExtension)
    }

    /// photocraft engine `lens_cmds::lens_params` (the `filter.lensCorrection` params a smart filter
    /// stores) and the engine's `lens_correction_runs_undoes_and_resolves_profiles` cases.
    @Test func engineCommandParams() throws {
        func lc(_ json: String) throws -> LensCorrection { try JSONDecoder().decode(LensCorrection.self, from: Data(json.utf8)) }
        func fails(_ json: String) -> Bool { (try? lc(json)) == nil }
        // Profiles: none / "" / generic (50 mm without a focal length) / auto (focal length, no EXIF here).
        #expect(try lc(#"{"profile":"none","focalLength":24}"#).profile == nil && lc(#"{"profile":""}"#).profile == nil)
        #expect(try lc(#"{"profile":"generic"}"#).profile == Lens.genericProfile(focal35mm: 50))
        #expect(try lc(#"{"profile":"generic","focalLength":-3}"#).profile == Lens.genericProfile(focal35mm: 50))
        #expect(try lc(#"{"profile":"auto","focalLength":24}"#).profile == Lens.genericProfile(focal35mm: 24))
        #expect(try lc(#"{"profile":"auto"}"#).profile == nil)
        #expect(fails(#"{"profile":"zeiss"}"#))
        // Edges.
        #expect(try lc(#"{"edge":"extension"}"#).edge == .edgeExtension && lc(#"{"edge":"edgeExtension"}"#).edge == .edgeExtension)
        #expect(try lc(#"{"edge":"black"}"#).edge == .color(SIMD4(0, 0, 0, 1)) && lc(#"{"edge":"white"}"#).edge == .color(SIMD4(1, 1, 1, 1)))
        #expect(try lc(#"{"edge":"background","edgeColor":[1,0.5,0]}"#).edge == .color(SIMD4(1, 0.5, 0, 1)))
        #expect(try lc(#"{"edge":"color","edgeColor":[0.2,"x",0.4,0.5]}"#).edge == .color(SIMD4(0.2, 0, 0.4, 0.5)))
        #expect(try lc(##"{"edge":"color","edgeColor":"#11223344"}"##).edge == .color(SIMD4(17, 34, 51, 68) / 255))
        #expect(try lc(##"{"edge":"color","edgeColor":"#1122"}"##).edge == .color(SIMD4(0, 0, 0, 1)))
        #expect(try lc(#"{"edge":"color"}"#).edge == .color(SIMD4(0, 0, 0, 1)))
        #expect(try lc(#"{"edge":7}"#).edge == .transparency)
        #expect(fails(#"{"edge":"rainbow"}"#))
        // Sliders: clamped to the dialog ranges; wrong types take the default (engine `num` / `flag`).
        let c = try lc(#"{"distortion":150,"redCyan":-300,"vignetteMidpoint":-5,"scale":10,"angle":400,"vertical":"x","correctCA":1,"correctVignette":false}"#)
        #expect(c == LensCorrection(correctVignette: false, distortion: 100, redCyan: -100, vignetteMidpoint: 0, angle: 400, scale: 50))
        #expect(try lc(#"{"correctCa":false}"#).correctCa == false && lc(#"{"correctCA":false,"correctCa":true}"#).correctCa == false)
        // Straighten adds the levelling angle; a malformed line throws.
        #expect(try abs(lc(#"{"angle":1,"straighten":[[0,0],[100,5]]}"#).angle - (1 - 2.862)) < 0.01)
        #expect(fails(#"{"straighten":[[0,0]]}"#) && fails(#"{"straighten":[[0,0],["a",1]]}"#))
        // Auto Scale resolves against the frame each run, and survives encoding.
        let frame = PixelRect(x: 0, y: 0, width: 60, height: 40)
        let auto = try lc(#"{"distortion":-40,"autoScale":true,"edge":"edgeExtension"}"#)
        #expect(auto.autoScale)
        let fixed = LensCorrection(distortion: -40, scale: Lens.autoScale(LensCorrection(distortion: -40), frame: frame), edge: .edgeExtension)
        #expect(fixed.scale > 100 && auto.resolved(frame: frame) == fixed)
        let img = TestImage.make(frame, channels: 4, alpha: true)
        let ctx = FilterContext(bounds: frame, mode: .rgb, alpha: true)
        #expect(try FilterEngine.apply(auto, to: img, context: ctx, on: .cpu).data == FilterEngine.apply(fixed, to: img, context: ctx, on: .cpu).data)
        #expect(try lc(String(decoding: JSONEncoder().encode(auto), as: UTF8.self)) == auto)
        // A profile object needs three vignette coefficients (photocraft `[f64; 3]`).
        #expect(fails(#"{"profile":{"name":"x","k1":0,"k2":0,"p1":0,"p2":0,"vignette":[0,0],"ca_red":0,"ca_blue":0}}"#))
        // Encoding is the engine shape and reads back exactly, generic profile or not.
        for l in [LensCorrection(), LensCorrection(profile: Lens.genericProfile(focal35mm: 16.5), angle: -3),
                  LensCorrection(profile: Lens.genericProfile(focal35mm: 85), correctCa: false, edge: .color(SIMD4(0.1, 0.2, 0.3, 0.4)))] {
            #expect(try lc(String(decoding: JSONEncoder().encode(l), as: UTF8.self)) == l)
        }
        let none = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(LensCorrection())) as? [String: Any])
        #expect(Set(none.keys) == ["profile", "correctDistortion", "correctVignette", "correctCA", "distortion", "redCyan", "blueYellow", "vignetteAmount",
                                   "vignetteMidpoint", "vertical", "horizontal", "angle", "scale", "edge"])
        #expect(none["profile"] as? String == "none" && none["edge"] as? String == "transparency")
    }

    static let cases: [LensCorrection] = [
        LensCorrection(),
        LensCorrection(distortion: 45, redCyan: -80, blueYellow: 60),
        LensCorrection(distortion: -70, vignetteAmount: -60, vignetteMidpoint: 30, edge: .edgeExtension),
        LensCorrection(profile: Lens.genericProfile(focal35mm: 14), vertical: -40, horizontal: 25, edge: .color(SIMD4(0.9, 0.2, 0.1, 0.6))),
        LensCorrection(vignetteAmount: 80, angle: 17, scale: 83),
        LensCorrection(profile: LensProfile(name: "t", k1: -0.1, k2: 0.03, p1: 0.01, p2: -0.008, vignette: [-0.4, 0.1, 0.02], caRed: 0.002, caBlue: -0.003),
                       angle: -8, scale: 140, edge: .edgeExtension),
        LensCorrection(vertical: 100, horizontal: -100, scale: 60),
    ]

    /// The Lens Correction filter on the GPU vs the CPU over the channel variants.
    @Test func lensParity() throws {
        var worst: Float = 0
        for (k, lc) in Self.cases.enumerated() {
            let e = try Parity.checkVariants(lc)
            #expect(e <= 1.0 / 255.0, "case \(k): \(e)")
            worst = max(worst, e)
        }
        ParityLog.record("LensCorrection", worst)
    }

    /// `Lens.correct` on dense images: an output tile in a frame larger than one GPU tile, an
    /// alpha channel added for Transparency, integer clipping before the edge-colour blend.
    @Test func lensCorrectDenseParity() throws {
        var worst: Float = 0
        let rect = PixelRect(x: -7, y: 4, width: 301, height: 197)
        for lc in [Self.cases[1], Self.cases[3], Self.cases[4]] {
            for storage in [SampleType.f32, .u8] {
                let e = try GEO.variants(rect) { img, ctx, b in try Lens.correct(img, lc, context: ctx, storage: storage, on: b) }
                guard let e else { return }
                #expect(e <= 1.0 / 255.0, "\(storage): \(e)")
                worst = max(worst, e)
            }
        }
        ParityLog.record("Lens.correct dense", worst)
    }

    /// The filter run over part of the frame gives the pixels of the whole-frame run (the tile
    /// grid is anchored at the frame).
    @Test func filterSubRectMatchesWholeFrame() throws {
        let frame = PixelRect(x: 0, y: 0, width: 300, height: 200)
        let img = TestImage.make(frame, channels: 4, alpha: true, seed: 3)
        let ctx = FilterContext(bounds: frame, mode: .rgb, alpha: true)
        for lc in Self.cases {
            for backend in [Backend.cpu, .auto] {
                let whole = try FilterEngine.apply(lc, to: img, output: frame, context: ctx, on: backend)
                let part = PixelRect(x: 70, y: 40, width: 150, height: 101)
                let sub = try FilterEngine.apply(lc, to: img, output: part, context: ctx, on: backend)
                #expect(Parity.maxError(whole.crop(part), sub, alpha: true) == 0)
            }
        }
    }
}

/// Release timings at 4096² RGBA (`PCALGO_PERF=1 swift test -c release --filter GeometryPerfTests`).
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["PCALGO_PERF"] != nil))
struct GeometryPerfTests {
    static func time(_ name: String, _ run: (Backend) throws -> FloatImage?) throws {
        _ = try run(.gpu)
        var gpu = Double.infinity
        for _ in 0..<3 {
            let t0 = Date()
            _ = try run(.gpu)
            gpu = min(gpu, Date().timeIntervalSince(t0))
        }
        let t0 = Date()
        _ = try run(.cpu)
        let cpu = Date().timeIntervalSince(t0)
        print(String(format: "PERF\t%@\tcpu %.1f ms\tgpu-wall %.1f ms", name, cpu * 1000, gpu * 1000))
    }

    @Test func geometry() throws {
        try PerfTests.time("LensCorrection distortion+CA+vignette", LensCorrection(profile: Lens.genericProfile(focal35mm: 16), redCyan: -40, vignetteAmount: 30))
        try PerfTests.time("LensCorrection perspective+angle", LensCorrection(vertical: -30, angle: 4, scale: 108, edge: .edgeExtension))
        let n = PerfTests.size
        let rect = PixelRect(x: 0, y: 0, width: n, height: n)
        let img = TestImage.make(rect, channels: 4, alpha: true, seed: 5)
        let ctx = FilterContext(bounds: rect, mode: .rgb, alpha: true)
        let wa = WideAngle(model: .fisheye, focalLength: 10, constraints: [.init(a: SIMD2(200, 300), b: SIMD2(Double(n) - 200, 320), orientation: .horizontal)])
        var t0 = Date()
        let mesh = wa.solve(frame: rect)
        print(String(format: "PERF\tAdaptiveWideAngle solve\tcpu %.1f ms", Date().timeIntervalSince(t0) * 1000))
        try Self.time("AdaptiveWideAngle render (bicubic)") { try MeshWarp.warpTriangles(img, srcRect: rect, verts: mesh.verts, tris: mesh.triangles(), interp: .bicubic, context: ctx, on: $0) }
        let pw = PuppetWarp(pins: [PuppetPin(src: SIMD2(1000, 1000), dst: SIMD2(1200, 900)), PuppetPin(src: SIMD2(3000, 3000), dst: SIMD2(3000, 3000))])
        t0 = Date()
        let pm = Puppet.buildMesh(img, bounds: rect, density: .normal, expansion: 2, context: ctx)
        let (_, v, order) = Puppet.deform(pm, pw)
        print(String(format: "PERF\tPuppetWarp mesh+solve\tcpu %.1f ms (%d verts)", Date().timeIntervalSince(t0) * 1000, pm.verts.count))
        let (verts, tris) = Puppet.renderMesh(pm, v, order)
        try Self.time("PuppetWarp render (bicubic)") { try MeshWarp.warpTriangles(img, srcRect: rect, verts: verts, tris: tris, interp: .bicubic, context: ctx, on: $0) }
    }
}
