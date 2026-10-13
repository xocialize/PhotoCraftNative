// Port of photocraft-algo (crates/algo/src/resample.rs tests), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import Testing
@testable import PCAlgo
import PCFoundation

/// Shared helpers of the resampling-area tests.
enum RS {
    /// CPU and GPU of `run` over the standard channel variants of a source over `rect`; the worst
    /// premultiplied difference (nil without Metal).
    static func variants(_ rect: PixelRect, seed: UInt32 = 1, hdr: Bool = false,
                         _ run: (FloatImage, FilterContext, Backend) throws -> FloatImage) throws -> Float? {
        guard AlgoGPU.isAvailable else { return nil }
        var worst: Float = 0
        let specs: [(Int, ColorMode, Bool)] = [(4, .rgb, true), (3, .rgb, false), (1, .grayscale, false), (2, .grayscale, true), (5, .cmyk, true)]
        for (ch, mode, a) in specs {
            let img = TestImage.make(rect, channels: ch, alpha: a, seed: seed, eightBit: !hdr, hdr: hdr)
            let ctx = FilterContext(bounds: rect, mode: mode, alpha: a)
            let c = try run(img, ctx, .cpu), g = try run(img, ctx, .gpu)
            #expect(c.rect == g.rect && c.channels == g.channels, "\(mode) \(ch)ch: CPU \(c.rect) GPU \(g.rect)")
            if c.rect != g.rect || c.channels != g.channels { return .infinity }
            worst = max(worst, Parity.maxError(c, g, alpha: a || c.channels > ch))
        }
        return worst
    }

    /// A surface of `format` holding `img` at its rectangle.
    static func surface(_ img: FloatImage, _ format: PixelFormat, defaultPixel: [Float]? = nil) -> Surface {
        var s = defaultPixel.map { Surface(format: format, defaultPixel: $0) } ?? Surface(format: format)
        s.writeRegion(img.rect, img.data)
        return s
    }

    static func maxDiff(_ a: [Float], _ b: [Float]) -> Float {
        zip(a, b).map { abs($0 - $1) }.max() ?? 0
    }
}

@Suite struct ResampleTests {
    func ramp(_ sample: SampleType) -> Surface {
        var s = Surface(format: PixelFormat(mode: .rgb, sample: sample, alpha: true))
        let r = PixelRect(x0: 0, y0: 0, x1: 64, y1: 32)
        let v: [Float] = (0..<32).flatMap { _ in (0..<64).flatMap { x in [Float(x) / 63, 0.5, 1 - Float(x) / 63, 1] } }
        s.writeRegion(r, v)
        return s
    }

    /// photocraft `fixed_channel_rows_match_dynamic_resampling` (whose subject, the fixed-N row
    /// kernels, has no Swift twin): the same tap configurations, checked for what both kernels
    /// rely on — weights plus the outside share sum to one, and windows stay in the clamp range.
    @Test func tapsAreNormalisedAndClamped() {
        for scale in [0.12, 0.5, 1.0, 2.3] {
            for filter in [ResampleKit.Kernel.nearest, .bilinear, ResampleKit.keys(.bicubic, scale), ResampleKit.keys(.bicubicSharper, scale), .lanczos] {
                for clamp in [nil, (Int32(-3), Int32(31))] as [(Int32, Int32)?] {
                    let ts = ResampleKit.taps(-5, 41, scale, filter, clamp, (-3, 31))
                    #expect(ts.count == 46)
                    for t in ts {
                        let s = t.weights.reduce(0, +) + t.outside
                        #expect(abs(s - 1) < 1e-4, "\(scale) \(filter) \(String(describing: clamp)): sum \(s)")
                        if !t.weights.isEmpty { #expect(t.start >= -3 && t.start + Int32(t.weights.count) - 1 <= 31) }
                    }
                }
            }
        }
    }

    /// photocraft `matches_photoshop_image_size`: Photoshop 25.4's Image Size of a 16-bit greyscale
    /// pattern, in levels of 32768, within 8 levels — on the CPU and through the Metal passes.
    @Test(arguments: [Backend.cpu, .gpu])
    func matchesPhotoshopImageSize(_ backend: Backend) {
        if backend == .gpu && !AlgoGPU.isAvailable { return }
        typealias Probe = (Bool, Resample, (Int32, Int32), (Int32, Int32), [Int])
        let cases: [Probe] = [
            (false, .bicubicSharper, (12, 10), (7, 16), [
                3777, 13165, 22219, 16176, 10460, 19488, 29643, 11249, 12634, 21696, 13330, 10319, 18965, 29120, 21280, 11204, 20279, 16184, 8200, 17548,
                27703, 21824, 10182, 19259, 26967, 5238, 16528, 26683, 17366, 8895, 17922, 32768, 2402, 15190, 25345, 17493, 7834, 16903, 31316, 1748,
                14172, 24326, 24718, 6368, 15746, 30390, 0, 13107, 23169, 31215, 4790, 14456, 27639, 5080, 11597, 21880, 29649, 3864, 13507, 24136, 20600,
                10264, 20931, 28009, 0, 12446, 21385, 28735, 8754, 19642, 26154, 4049, 10895, 20832, 23523, 7620, 18485, 23204, 20126, 8787, 19818, 21447,
                6173, 17467, 20390, 31862, 6616, 18480, 24094, 6500, 16129, 19749, 27472, 5810, 17460, 28281, 7655, 15108, 18394, 25515, 4427, 16043,
                28749, 7026, 13691, 17871, 24992, 3904, 15520, 27200, 6075, 13168,
            ]),
            (false, .bicubicAutomatic, (12, 10), (7, 16), [
                4201, 12337, 27677, 15894, 4816, 20021, 29631, 10348, 9882, 27304, 14492, 3766, 19574, 29046, 18743, 5944, 25299, 16116, 4147, 17829,
                27787, 19399, 4206, 21790, 23748, 7966, 15117, 26569, 15941, 2695, 19445, 28341, 10104, 13050, 25465, 16251, 2613, 18023, 26770, 8432,
                11951, 24281, 22800, 7141, 15351, 24790, 5953, 11004, 23130, 28322, 10921, 12440, 24940, 9659, 9368, 22012, 27611, 10006, 10488, 26419,
                18657, 7071, 20807, 25492, 6937, 9239, 26574, 22363, 5435, 19688, 24808, 9136, 8184, 25295, 19708, 3939, 18677, 25053, 18234, 7120, 24061,
                17941, 2545, 17568, 24869, 23748, 6081, 21401, 21862, 6018, 15056, 23602, 22177, 4859, 17816, 28450, 11911, 11653, 22253, 20263, 3595,
                15790, 29734, 12969, 9683, 21668, 19678, 3010, 15424, 28429, 11728, 9300,
            ]),
            (false, .bicubic, (12, 10), (20, 6), [
                11517, 10000, 8617, 9364, 12272, 16362, 21396, 25508, 25506, 19474, 10887, 5289, 5842, 10286, 14986, 18566, 21910, 25511, 28611, 29922,
                24788, 17949, 8497, 4593, 7309, 12594, 17150, 20945, 24892, 26196, 22979, 16123, 9691, 7483, 10061, 14653, 18841, 22420, 25514, 26824,
                25702, 23396, 17586, 11378, 8127, 8882, 12310, 17039, 22345, 25871, 24700, 18125, 9951, 5493, 6802, 11215, 15576, 19259, 22384, 23694,
                26692, 26985, 22732, 14270, 6889, 4950, 8348, 13583, 17529, 21570, 25966, 27275, 22817, 14643, 8068, 6911, 10694, 15930, 19443, 20705,
                21499, 23413, 25601, 24336, 18665, 11686, 7800, 8947, 12974, 18067, 22707, 25285, 23077, 16645, 9789, 6586, 8147, 12329, 15935, 17465,
                17962, 20462, 24615, 25377, 20036, 11458, 5421, 5415, 9528, 14134, 17782, 22482, 26926, 27479, 21881, 13308, 7533, 7734, 11549, 13992,
            ]),
            (false, .bicubicSmoother, (40, 3), (9, 3), [
                11315, 18740, 17475, 15974, 16503, 16042, 18215, 14712, 16238, 18482, 14351, 14664, 18012, 20260, 13338, 15511, 18468, 18275, 16790, 19168,
                14745, 14998, 20341, 18150, 13819, 16493, 16432,
            ]),
            (false, .bilinear, (12, 10), (5, 4), [11316, 14541, 17920, 10855, 24679, 19763, 9933, 23757, 6247, 20070, 25601, 5325, 19149, 17306, 15463, 20992, 16384, 14541, 23143, 10854]),
            (false, .nearest, (12, 10), (7, 16), [
                1638, 12698, 23757, 3482, 9011, 20070, 31130, 1638, 12698, 23757, 3482, 9011, 20070, 31130, 31130, 10854, 21914, 1638, 7168, 18227, 29286,
                29286, 9011, 20070, 31130, 5325, 16384, 27443, 29286, 9011, 20070, 31130, 5325, 16384, 27443, 27443, 7168, 18227, 29286, 3482, 14541,
                25600, 25600, 5325, 16384, 27443, 1638, 12698, 23757, 25600, 5325, 16384, 27443, 1638, 12698, 23757, 23757, 3482, 14541, 25600, 31130,
                10854, 21914, 23757, 3482, 14541, 25600, 31130, 10854, 21914, 21914, 1638, 12698, 23757, 29286, 9011, 20070, 20070, 31130, 10854, 21914,
                27443, 7168, 18227, 20070, 31130, 10854, 21914, 27443, 7168, 18227, 18227, 29286, 9011, 20070, 25600, 5325, 16384, 16384, 27443, 7168,
                18227, 23757, 3482, 14541, 16384, 27443, 7168, 18227, 23757, 3482, 14541,
            ]),
            (true, .bicubic, (12, 10), (20, 6), [
                9960, 6313, 993, 0, 4525, 14807, 26472, 32768, 32768, 23510, 10514, 0, 0, 0, 10110, 22576, 31764, 32768, 32768, 32768, 26136, 18594, 6164,
                0, 0, 2565, 14499, 26983, 32768, 32768, 26358, 14709, 3969, 0, 0, 6602, 17734, 27952, 32768, 32768, 31590, 27808, 18307, 7429, 0, 0, 3712,
                14435, 26473, 32768, 31131, 20665, 7535, 0, 0, 2177, 13238, 25049, 32768, 32768, 32768, 32768, 26136, 14174, 2548, 0, 0, 6190, 18705,
                30273, 32768, 32768, 25517, 13238, 2177, 0, 0, 7250, 19418, 26624, 32768, 32768, 32768, 28203, 18522, 7200, 0, 0, 3285, 14794, 26862,
                32768, 29913, 19013, 6667, 0, 0, 4443, 14506, 20751, 17344, 23066, 31075, 32361, 23949, 10738, 0, 0, 0, 10110, 22657, 32768, 32768, 32768,
                22658, 10192, 1004, 0, 0, 0,
            ]),
            (true, .bicubicSharper, (12, 10), (7, 16), [
                801, 3050, 32489, 16260, 0, 29819, 32767, 9161, 1781, 29578, 14350, 0, 32768, 32767, 21132, 0, 25409, 17862, 0, 26925, 32767, 22769, 0,
                24839, 27566, 0, 9397, 32768, 19813, 0, 27795, 32768, 0, 0, 32768, 20744, 0, 25797, 32768, 0, 0, 32768, 27555, 0, 11184, 32768, 0, 0,
                32768, 32768, 0, 0, 32768, 5110, 0, 30386, 32768, 0, 0, 32768, 20385, 0, 23267, 32768, 0, 0, 32768, 29130, 0, 19191, 32768, 2670, 0, 31290,
                25387, 0, 21263, 32767, 20198, 0, 21586, 24510, 0, 23714, 32768, 32768, 0, 14165, 27804, 1007, 14254, 32768, 30149, 0, 16077, 32112, 2886,
                1884, 21043, 29607, 0, 16384, 32768, 3566, 0, 12683, 29616, 0, 16384, 32768, 3196, 0,
            ]),
            (true, .bicubicSharper, (12, 10), (20, 6), [
                9273, 5043, 0, 0, 2698, 14484, 28464, 32768, 32768, 24841, 10877, 0, 0, 0, 9684, 22346, 31492, 32768, 32768, 32768, 25960, 18430, 4978, 0,
                0, 977, 15047, 28475, 32768, 32768, 27939, 14157, 1813, 0, 0, 5296, 17828, 28439, 32768, 32768, 32768, 27849, 17576, 6209, 0, 0, 2169,
                15076, 28935, 32768, 32768, 22167, 7399, 0, 0, 211, 12977, 24638, 32768, 32768, 32768, 32768, 25960, 14244, 824, 0, 0, 5093, 18802, 31993,
                32768, 32768, 26467, 12977, 211, 0, 0, 6300, 19418, 26712, 32768, 32768, 32768, 27907, 17874, 5820, 0, 0, 1853, 16055, 29518, 32768, 32768,
                20889, 5880, 0, 0, 2879, 13798, 20185, 19010, 25565, 32768, 32302, 25431, 11478, 0, 0, 0, 9684, 23083, 32768, 32768, 32768, 23084, 10422,
                1276, 0, 0, 0,
            ]),
        ]
        for (binary, filter, (w, h), (wo, ho), want) in cases {
            var s = Surface(format: PixelFormat(mode: .grayscale, sample: .u16, alpha: false))
            let canvas = PixelRect(x0: 0, y0: 0, x1: w, y1: h)
            func level(_ x: Int32, _ y: Int32) -> Float {
                let k = Float((x * 37 + y * 101) % 17)
                if binary { return k > 8 ? 32767.0 / 32768.0 : 0 }
                return ((k / 16 * 0.9 + 0.05) * 32768).rounded() / 32768
            }
            let px: [Float] = (0..<h).flatMap { y in (0..<w).map { x in level(x, y) } }
            s.writeRegion(canvas, px)
            let o = Resample.resizeSurfaceInCanvas(s, sx: Double(wo) / Double(w), sy: Double(ho) / Double(h), filter: filter, canvas: canvas, on: backend)
            let got = o.readRegion(PixelRect(x0: 0, y0: 0, x1: wo, y1: ho))
            #expect(got.count == want.count, "\(filter)")
            let worst = zip(got, want).map { abs($0 * 32768 - Float($1)) }.max() ?? .infinity
            #expect(worst <= 8, "\(backend) \(filter) \(w)x\(h) to \(wo)x\(ho): \(worst) levels of 32768 from Photoshop")
        }
    }

    /// photocraft `bicubic_is_photoshops_keys_cubic`: an impulse doubled spreads as −9, −27, 67,
    /// 225 /256 and back (Keys a = −0.75; Catmull-Rom would be −0.5).
    @Test(arguments: [Backend.cpu, .gpu])
    func bicubicIsPhotoshopsKeysCubic(_ backend: Backend) {
        if backend == .gpu && !AlgoGPU.isAvailable { return }
        var s = Surface(format: .gray32f)
        var row = [Float](repeating: 0.25, count: 30)
        row[10] = 0.75
        s.writeRegion(PixelRect(x0: 0, y0: 0, x1: 30, y1: 1), row)
        let o = Resample.resizeSurface(s, sx: 2, sy: 1, filter: .bicubic, on: backend)
        let got = o.readRegion(PixelRect(x0: 17, y0: 0, x1: 25, y1: 1)).map { ($0 - 0.25) * 512 }
        for (g, want) in zip(got, [Float(-9), -27, 67, 225, 225, 67, -27, -9]) {
            #expect(abs(g - want) < 1e-3, "\(got)")
        }
    }

    @Test func identityScaleIsLossless() {
        for f in [Resample.nearest, .bilinear, .bicubic, .lanczos] {
            for backend in [Backend.cpu, .auto] {
                let s = ramp(.u16)
                let o = Resample.resizeSurface(s, sx: 1, sy: 1, filter: f, on: backend)
                let r = PixelRect(x0: 0, y0: 0, x1: 64, y1: 32)
                let d = RS.maxDiff(s.readRegion(r), o.readRegion(r))
                #expect(d < 1e-4, "\(f) \(d)")
            }
        }
    }

    @Test func halfAndDoubleSizes() {
        for f in [Resample.nearest, .bilinear, .bicubic, .lanczos, .preserveDetails] {
            for backend in [Backend.cpu, .auto] {
                let s = ramp(.f32)
                let half = Resample.resizeSurface(s, sx: 0.5, sy: 0.5, filter: f, on: backend)
                #expect(half.contentBounds == PixelRect(x0: 0, y0: 0, x1: 32, y1: 16), "\(f)")
                let p = half.pixel(x: 16, y: 8)
                #expect(abs(p[1] - 0.5) < 0.02 && abs(p[3] - 1) < 1e-3, "\(f) \(p)")
                let dbl = Resample.resizeSurface(s, sx: 2, sy: 2, filter: f, on: backend)
                #expect(dbl.contentBounds == PixelRect(x0: 0, y0: 0, x1: 128, y1: 64), "\(f)")
                // Mid-gray channel and the ramp's monotonicity are preserved.
                let row = (Int32(8)..<120).map { dbl.pixel(x: $0, y: 30)[0] }
                #expect(zip(row, row.dropFirst()).allSatisfy { $1 >= $0 - 0.02 }, "\(f)")
            }
        }
    }

    @Test func downscaleAveragesCheckerboard() {
        var s = Surface(format: .rgba8)
        for y in Int32(0)..<64 { for x in Int32(0)..<64 { let v = Float((x + y) % 2); s.setPixel(x: x, y: y, [v, v, v, 1]) } }
        for backend in [Backend.cpu, .auto] {
            let o = Resample.resizeSurface(s, sx: 0.25, sy: 0.25, filter: .bicubic, on: backend)
            let p = o.pixel(x: 8, y: 8)
            #expect(abs(p[0] - 0.5) < 0.05, "\(p)")
        }
    }

    @Test func transparentEdgesDoNotDarken() {
        var s = Surface(format: .rgba32f)
        s.fill(PixelRect(x0: 10, y0: 10, x1: 20, y1: 20), with: [1, 0, 0, 1])
        for backend in [Backend.cpu, .auto] {
            let o = Resample.resizeSurface(s, sx: 1.7, sy: 1.7, filter: .lanczos, on: backend)
            let edge = o.pixel(x: 17, y: 25)
            #expect(edge[3] > 0 && abs(edge[0] - 1) < 0.05 && abs(edge[1]) < 0.05, "\(edge)")
        }
    }

    /// Image Size of a layer that fills the canvas: its edges stay opaque and keep their colour,
    /// up or down, at every depth; a layer away from the edges keeps its soft border.
    @Test func canvasEdgesRepeatInsteadOfFading() {
        let canvas = PixelRect(x0: 0, y0: 0, x1: 30, y1: 20)
        let colour: [Float] = [0.2, 0.6, 1.0, 1.0]
        let filters: [Resample] = [.nearest, .bilinear, .bicubic, .lanczos, .preserveDetails]
        for sample in [SampleType.u8, .u16, .f32] {
            let fmt = PixelFormat(mode: .rgb, sample: sample, alpha: true)
            var s = Surface(format: fmt)
            s.fill(canvas, with: colour)
            for f in filters {
                for k in [2.0, 1.37, 0.5] {
                    for backend in [Backend.cpu, .auto] {
                        let o = Resample.resizeSurfaceInCanvas(s, sx: k, sy: k, filter: f, canvas: canvas, on: backend)
                        let dst = Resample.scaledRect(canvas, sx: k, sy: k)
                        #expect(o.contentBounds == dst, "\(sample) \(f) \(k) \(backend)")
                        for (x, y) in [(Int32(0), Int32(0)), (dst.x1 - 1, 0), (0, dst.y1 - 1), (dst.x1 - 1, dst.y1 - 1), (dst.x1 / 2, 0), (0, dst.y1 / 2)] {
                            let p = o.pixel(x: x, y: y)
                            let off = zip(p, colour).map { abs($0 - $1) }.max()!
                            #expect(off < 0.01, "\(sample) \(f) \(k) (\(x),\(y)): \(p)")
                        }
                    }
                }
            }
            // Inside the canvas the default pixel is still what lies around a layer.
            var inner = Surface(format: fmt)
            inner.fill(PixelRect(x0: 10, y0: 5, x1: 20, y1: 15), with: [1, 0, 0, 1])
            let r = PixelRect(x0: 0, y0: 0, x1: 60, y1: 40)
            let a = Resample.resizeSurfaceInCanvas(inner, sx: 1.7, sy: 1.7, filter: .lanczos, canvas: canvas, on: .cpu)
            #expect(a.readRegion(r) == Resample.resizeSurface(inner, sx: 1.7, sy: 1.7, filter: .lanczos, on: .cpu).readRegion(r), "\(sample)")
        }
    }

    /// Two tiles in opposite corners of a 100000 px square: the content bounds are huge but almost
    /// nothing is stored. Shrinking it to one pixel must neither allocate a window proportional to
    /// the scale nor read the empty middle (photocraft #713).
    @Test func tinyTargetOfAHugeSparseSource() {
        var s = Surface(format: .rgba32f)
        s.fill(PixelRect(x0: 0, y0: 0, x1: 256, y1: 256), with: [1, 1, 1, 1])
        s.fill(PixelRect(x0: 99_840, y0: 99_840, x1: 100_096, y1: 100_096), with: [1, 1, 1, 1])
        let k = 1.0 / 100_096.0
        let o = Resample.resizeSurface(s, sx: k, sy: k, filter: .bicubic, on: .auto)
        #expect(o.contentBounds == PixelRect(x0: 0, y0: 0, x1: 1, y1: 1))
        let p = o.pixel(x: 0, y: 0)
        // Two 256² tiles out of 100096²: nearly transparent, and white where it isn't.
        #expect(p[3] >= 0 && p[3] < 1e-3 && p.allSatisfy(\.isFinite), "\(p)")
        // Squashed to one row but kept wide: the whole height feeds one band of output rows, which
        // must not hold a full-height intermediate.
        let o2 = Resample.resizeSurface(s, sx: 1000.0 / 100_096.0, sy: k, filter: .bicubic, on: .auto)
        let b = o2.contentBounds
        #expect(b.height == 1 && (1000...1001).contains(b.width), "\(b)")
        #expect(o2.pixel(x: 0, y: 0)[3] > 0 && o2.pixel(x: 500, y: 0)[3] == 0, "\(o2.pixel(x: 0, y: 0)) \(o2.pixel(x: 500, y: 0))")
    }

    /// Tile rows with nothing stored are not read; they count as rows of the default pixel, exactly
    /// as reading them would (and within rounding for a non-zero default).
    @Test func skippedEmptyRowsMatchReadingThem() {
        for (fmt, def, tol) in [(PixelFormat.rgba32f, [Float](repeating: 0, count: 4), Float(0)), (PixelFormat.gray8, [Float(1)], Float(1e-6))] {
            var sparse = Surface(format: fmt, defaultPixel: def)
            sparse.fill(PixelRect(x0: 0, y0: 0, x1: 300, y1: 40), with: [Float](repeating: 0.5, count: def.count))
            sparse.fill(PixelRect(x0: 100, y0: 1500, x1: 400, y1: 1540), with: [Float](repeating: 0.25, count: def.count))
            // The same pixels with the empty rows stored as tiles of the default pixel.
            var dense = sparse
            dense.fill(PixelRect(x0: 0, y0: 40, x1: 400, y1: 1500), with: def)
            #expect(dense.tileCount > sparse.tileCount)
            for f in [Resample.bilinear, .bicubic, .lanczos] {
                for (kx, ky) in [(0.013, 0.013), (0.37, 0.37), (1.0, 0.01)] {
                    let a = Resample.resizeSurface(sparse, sx: kx, sy: ky, filter: f, on: .cpu)
                    let b = Resample.resizeSurface(dense, sx: kx, sy: ky, filter: f, on: .cpu)
                    let r = a.contentBounds.union(b.contentBounds)
                    let d = RS.maxDiff(a.readRegion(r), b.readRegion(r))
                    #expect(d <= tol, "\(fmt) \(f) \(kx) \(ky): \(d)")
                }
            }
        }
    }

    /// Reading the source in row chunks gives exactly what one read of the whole window gives.
    @Test func chunkedReadsMatchASingleRead() {
        var s = ramp(.f32)
        s.fill(PixelRect(x0: 600, y0: 700, x1: 640, y1: 720), with: [0.3, 0.9, 0.1, 0.5])
        var mask = Surface(format: .gray8, defaultPixel: [1])
        mask.fill(PixelRect(x0: 0, y0: 0, x1: 40, y1: 30), with: [0])
        mask.fill(PixelRect(x0: 500, y0: 900, x1: 530, y1: 940), with: [0.25])
        for src in [s, mask] {
            for f in [Resample.nearest, .bilinear, .bicubic, .lanczos] {
                for k in [0.013, 0.37, 1.6] {
                    let whole = ResampleKit.resizeSurface(src, sx: k, sy: k, filter: f, canvas: nil, budget: .max, backend: .cpu)
                    let chunked = ResampleKit.resizeSurface(src, sx: k, sy: k, filter: f, canvas: nil, budget: 1, backend: .cpu)
                    let r = whole.contentBounds.union(chunked.contentBounds)
                    #expect(whole.readRegion(r) == chunked.readRegion(r), "\(f) \(k)")
                }
            }
        }
    }

    @Test func masksKeepDefaultPixel() {
        var m = Surface(format: .gray8, defaultPixel: [1])
        m.fill(PixelRect(x0: 0, y0: 0, x1: 10, y1: 10), with: [0])
        for backend in [Backend.cpu, .auto] {
            let o = Resample.resizeSurface(m, sx: 2, sy: 2, filter: .bilinear, on: backend)
            #expect(o.defaultPixelValue == [1])
            #expect(o.pixel(x: 5, y: 5)[0] < 0.01)
        }
    }

    @Test func translateAndCrop() {
        let s = ramp(.u8)
        let t = Resample.translateSurface(s, dx: 5, dy: -3)
        #expect(t.pixel(x: 15, y: 7) == s.pixel(x: 10, y: 10))
        let c = Resample.cropSurface(s, keep: PixelRect(x0: 0, y0: 0, x1: 10, y1: 10))
        #expect(c.contentBounds == PixelRect(x0: 0, y0: 0, x1: 10, y1: 10))
    }

    /// photocraft #1114: nearest neighbour reduction must sample single source pixels, never average.
    @Test func nearestNeighborReductionDoesNotAverage() {
        var s = Surface(format: .gray8)
        for y in Int32(0)..<8 { for x in Int32(0)..<8 where (x + y) % 2 == 0 { s.fill(PixelRect(x0: x, y0: y, x1: x + 1, y1: y + 1), with: [1]) } }
        for backend in [Backend.cpu, .auto] {
            let reduced = Resample.resizeSurface(s, sx: 0.5, sy: 0.5, filter: .nearest, on: backend)
            for y in Int32(0)..<4 {
                for x in Int32(0)..<4 {
                    let p = reduced.pixel(x: x, y: y)[0]
                    #expect(p == 0 || p == 1, "nearest produced an averaged value \(p) at (\(x), \(y))")
                }
            }
        }
    }

    /// The dense-image API gives the surface API's pixels (f32 storage, transparent default).
    @Test func denseImageMatchesSurface() throws {
        let rect = PixelRect(x: 3, y: 2, width: 45, height: 31)
        let img = TestImage.make(rect, channels: 4, alpha: true, seed: 4)
        let s = RS.surface(img, .rgba32f)
        for f in Resample.allCases {
            for (sx, sy) in [(1.7, 1.7), (0.41, 0.63), (2.2, 0.6), (0.2, 0.13)] {
                let a = Resample.resizeSurface(s, sx: sx, sy: sy, filter: f, on: .cpu)
                let b = try Resample.resize(img, sx: sx, sy: sy, filter: f, on: .cpu)
                #expect(b.rect == Resample.scaledRect(rect, sx: sx, sy: sy))
                let d = RS.maxDiff(a.readRegion(b.rect), b.data)
                #expect(d < 1e-6, "\(f) \(sx)×\(sy): \(d)")
            }
        }
    }

    @Test func resizeToPixelSize() throws {
        let img = TestImage.make(PixelRect(x: 0, y: 0, width: 12, height: 10), channels: 3, alpha: false)
        let r = try Resample.resize(img, to: PixelSize(width: 7, height: 16), filter: .bicubicAutomatic, on: .cpu)
        #expect(r.rect == PixelRect(x: 0, y: 0, width: 7, height: 16))
    }

    @Test func codableNamesMatchPhotocraft() throws {
        let json = try JSONEncoder().encode([Resample.bicubicSmoother, .preserveDetails, .nearest])
        #expect(String(decoding: json, as: UTF8.self) == "[\"bicubicSmoother\",\"preserveDetails\",\"nearest\"]")
        #expect(Resample.default == .bicubic && Interp.default == .bicubic)
        #expect(Interp(parsing: "nearestNeighbor") == .nearest && Interp(parsing: "x") == .bicubic)
    }
}
