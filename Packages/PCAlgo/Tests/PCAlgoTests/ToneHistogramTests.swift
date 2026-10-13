// Port of photocraft-algo (crates/algo/src/histogram.rs tests), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Testing
@testable import PCAlgo
import PCFoundation

@Suite struct ToneHistogramTests {
    static var backends: [Backend] { AlgoGPU.isAvailable ? [.cpu, .gpu] : [.cpu] }

    static func hist(_ px: [SIMD4<Float>], _ b: Backend) throws -> RgbHistogram { try RgbHistogram.compute(rgba: px, on: b) }

    /// GPU counts equal the CPU's exactly, on test images of every model (through RGBA), HDR
    /// images, special values and a large random buffer.
    @Test func histogramParityIsExact() throws {
        guard AlgoGPU.isAvailable else { return }
        var images: [[SIMD4<Float>]] = []
        let r = PixelRect(x: 3, y: -2, width: 61, height: 47)
        for (img, ctx) in TestImage.variants(r, seed: 4) { images.append(ToneKit.rgbaPixels(img, r, ctx)) }
        let hdr = TestImage.make(r, channels: 4, alpha: true, seed: 5, eightBit: false, hdr: true)
        images.append(ToneKit.rgbaPixels(hdr, r, FilterContext(bounds: r, mode: .rgb, alpha: true)))
        var big = [SIMD4<Float>](repeating: .zero, count: 1024 * 1024)
        for i in 0..<big.count {
            let x = Int32(i % 1024), y = Int32(i / 1024)
            big[i] = SIMD4(hash01(x, y, 0, 3) * 1.2 - 0.1, hash01(x, y, 1, 3), Float(i % 256) / 255, i % 17 == 0 ? 0 : hash01(x, y, 3, 3))
        }
        big[5] = SIMD4(.nan, 0, 0, 1); big[6] = SIMD4(0, .infinity, 0, 1); big[7] = SIMD4(0, 0, 0, .nan); big[8] = SIMD4(-.infinity, 0, 0, 0)
        images.append(big)
        // Values on bin boundaries (k + 0.5) / 255, where an fma would round differently.
        images.append((0..<4096).map { i in let v = (Float(i % 256) + 0.5) / 255 + Float(i / 256) * 1e-8; return SIMD4(v, v.nextUp, v.nextDown, 1) })
        for px in images {
            let c = RgbHistogram(rgba: px), g = try RgbHistogram.compute(rgba: px, on: .gpu)
            #expect(c == g)
        }
        ParityLog.record("RgbHistogram", 0)
    }

    /// photocraft `exact_bins_and_channel_totals`.
    @Test func exactBinsAndChannelTotals() throws {
        for b in Self.backends {
            let pixels = (0..<256).map { i in SIMD4(Float(i) / 255, Float(255 - i) / 255, 0.5, 0.25) }
            let h = try Self.hist(pixels, b)
            #expect(h.samples == 256)
            #expect(h.channels[0].allSatisfy { $0 == 1 })
            #expect(h.channels[1].allSatisfy { $0 == 1 })
            #expect(h.channels[2][128] == 256)
            for ch in h.channels { #expect(ch.reduce(0, +) == h.samples) }
        }
    }

    /// photocraft `empty_transparent_invalid_and_hdr_are_explicit`.
    @Test func emptyTransparentInvalidAndHDRAreExplicit() throws {
        for b in Self.backends {
            #expect(try Self.hist([], b) == RgbHistogram())
            let pixels: [SIMD4<Float>] = [SIMD4(0.7, 0.9, 0.4, 0), SIMD4(.nan, 0, 0, 1), SIMD4(0, .infinity, 0, 1), SIMD4(0, 0, 0, .nan), SIMD4(-2, 4, 0.5, 1)]
            let h = try Self.hist(pixels, b)
            #expect((h.samples, h.transparent, h.invalid) == (1, 1, 3))
            #expect(h.underflow == [1, 0, 0])
            #expect(h.overflow == [0, 1, 0])
            #expect((h.channels[0][0], h.channels[1][255], h.channels[2][128]) == (1, 1, 1))
        }
    }

    /// photocraft `clipping_indicators_use_exact_samples_not_edge_bin_rounding`.
    @Test func clippingIndicatorsUseExactSamples() throws {
        for b in Self.backends {
            let h = try Self.hist([SIMD4(0.0001, 0.9999, 0.5, 1), SIMD4(-0.2, 1, 0, 1), SIMD4(0, 1, 0, 0)], b)
            #expect(h.shadows == [1, 0, 1])
            #expect(h.highlights == [0, 1, 0])
            #expect(h.channels[0][0] == 2)
            #expect(h.channels[1][255] == 2)
        }
    }

    /// photocraft `rgb_and_gray_at_all_depths_use_the_same_float_contract`.
    @Test func rgbAndGrayAtAllDepthsUseTheSameFloatContract() throws {
        for mode in [ColorMode.rgb, .grayscale] {
            for sample in SampleType.allCases {
                var s = Surface(format: PixelFormat(mode: mode, sample: sample, alpha: true))
                for (x, v) in [Float(0), 0.25, 0.75, 1].enumerated() {
                    s.setPixel(x: Int32(x), y: 0, mode == .rgb ? [v, v, v, 1] : [v, 1])
                }
                let pixels = s.readRGBA(PixelRect(x: 0, y: 0, width: 4, height: 1))
                for b in Self.backends {
                    let h = try Self.hist(pixels, b)
                    #expect(h.samples == 4, "\(mode)/\(sample)")
                    for c in h.channels { for bin in [0, 64, 191, 255] { #expect(c[bin] == 1, "\(mode)/\(sample) bin \(bin)") } }
                }
            }
        }
    }

    /// photocraft `exact_clipping_endpoints_not_quantized_neighbours`.
    @Test func exactClippingEndpoints() {
        #expect(RgbHistogram.clipping(SIMD4(0.0001, 0.9999, 0.5, 1)) == (0, 0))
        #expect(RgbHistogram.clipping(SIMD4(-0.1, 1, 0, 1)) == (5, 2))
        #expect(RgbHistogram.clipping(SIMD4(0, 1, 0, 0)) == (0, 0))
        #expect(RgbHistogram.clipping(SIMD4(0, .infinity, 0, 1)) == (0, 0))
    }
}
