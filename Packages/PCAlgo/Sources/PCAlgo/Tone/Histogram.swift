// Port of photocraft-algo (crates/algo/src/histogram.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Bounded RGB histograms of straight, normalised float RGBA samples. No colour conversion: bins
// describe the supplied sample domain. 256 bins are a display resolution, not an input bit depth.
// The Metal path is a grid-stride reduction into threadgroup-local atomic bins merged into global
// ones; counts are integers, so it matches the CPU exactly (32-bit counters on the GPU: fewer than
// 2³² pixels per call).

import Foundation
import Metal
import PCFoundation

/// photocraft `RgbHistogram`: 256 bins per channel plus the sample accounting.
public struct RgbHistogram: Sendable, Hashable, Codable {
    /// photocraft `BINS`.
    public static let bins = 256

    /// `channels[c][bin]` for R, G, B.
    public var channels: [[UInt64]]
    public var samples: UInt64
    public var transparent: UInt64
    public var invalid: UInt64
    /// Finite samples outside 0…1 are included in the edge bins and counted here.
    public var underflow: [UInt64]
    public var overflow: [UInt64]
    /// Exact endpoints (≤ 0 / ≥ 1), before display-bin rounding. A near-white value is not clipped.
    public var shadows: [UInt64]
    public var highlights: [UInt64]

    public init() {
        channels = [[UInt64]](repeating: [UInt64](repeating: 0, count: Self.bins), count: 3)
        samples = 0; transparent = 0; invalid = 0
        underflow = [0, 0, 0]; overflow = [0, 0, 0]; shadows = [0, 0, 0]; highlights = [0, 0, 0]
    }

    /// Clipped channels of one visible straight RGBA pixel as bit masks (bit 0 = R, 1 = G, 2 = B):
    /// `(shadows, highlights)` at exact endpoints ≤ 0 / ≥ 1. Transparent and non-finite pixels clip
    /// nothing (photocraft `clipping`).
    public static func clipping(_ p: SIMD4<Float>) -> (shadows: UInt8, highlights: UInt8) {
        if p.w <= 0 || !(p.x.isFinite && p.y.isFinite && p.z.isFinite && p.w.isFinite) { return (0, 0) }
        var s: UInt8 = 0, h: UInt8 = 0
        for c in 0..<3 {
            if p[c] <= 0 { s |= 1 << c }
            if p[c] >= 1 { h |= 1 << c }
        }
        return (s, h)
    }

    /// Each visible pixel counts once, including partially transparent ones. Non-finite pixels are
    /// rejected as a whole; transparent RGB cannot contribute phantom peaks (photocraft
    /// `RgbHistogram::from_rgba`). Chunked in parallel; integer counts make the order irrelevant.
    public init(rgba pixels: [SIMD4<Float>]) {
        let chunks = max(1, min(64, pixels.count / 65536))
        let per = (pixels.count + chunks - 1) / chunks
        var parts = [RgbHistogram](repeating: RgbHistogram(), count: chunks)
        pixels.withUnsafeBufferPointer { px in
            parts.withUnsafeMutableBufferPointer { pb in
                let ps = UnsafeSendable(pb)
                parallelFor(chunks) { k in
                    var h = RgbHistogram()
                    let lo = k * per, hi = min(px.count, lo + per)
                    if lo < hi { for i in lo..<hi { h.add(px[i]) } }
                    ps.value[k] = h
                }
            }
        }
        self.init()
        for p in parts { merge(p) }
    }

    /// Counts one pixel.
    @inline(__always)
    mutating func add(_ pixel: SIMD4<Float>) {
        if !pixel.w.isFinite { Self.inc(&invalid); return }
        if pixel.w <= 0 { Self.inc(&transparent); return }
        if !(pixel.x.isFinite && pixel.y.isFinite && pixel.z.isFinite) { Self.inc(&invalid); return }
        Self.inc(&samples)
        let (low, high) = Self.clipping(pixel)
        for c in 0..<3 {
            let value = pixel[c]
            if low & (1 << c) != 0 { Self.inc(&shadows[c]) }
            if high & (1 << c) != 0 { Self.inc(&highlights[c]) }
            if value < 0 { Self.inc(&underflow[c]) } else if value > 1 { Self.inc(&overflow[c]) }
            // The preview encoder's nearest-bin rule, before it loses float precision.
            let bin = Int(clampf(value, 0, 1) * Float(Self.bins - 1) + 0.5)
            if bin < Self.bins { Self.inc(&channels[c][bin]) }
        }
    }

    @inline(__always)
    static func inc(_ v: inout UInt64, _ n: UInt64 = 1) {
        let (r, o) = v.addingReportingOverflow(n)
        v = o ? .max : r
    }

    mutating func merge(_ o: RgbHistogram) {
        Self.inc(&samples, o.samples); Self.inc(&transparent, o.transparent); Self.inc(&invalid, o.invalid)
        for c in 0..<3 {
            Self.inc(&underflow[c], o.underflow[c]); Self.inc(&overflow[c], o.overflow[c])
            Self.inc(&shadows[c], o.shadows[c]); Self.inc(&highlights[c], o.highlights[c])
            for b in 0..<Self.bins { Self.inc(&channels[c][b], o.channels[c][b]) }
        }
    }

    /// The histogram of straight RGBA pixels on the CPU (`.cpu`) or the GPU (`.gpu`, `.auto` when
    /// Metal is available and the buffer is large enough to pay for the upload).
    public static func compute(rgba pixels: [SIMD4<Float>], on backend: Backend = .auto) throws -> RgbHistogram {
        switch backend {
        case .cpu: return RgbHistogram(rgba: pixels)
        case .gpu: return try gpu(pixels)
        case .auto: return AlgoGPU.isAvailable && pixels.count >= 1 << 16 ? try gpu(pixels) : RgbHistogram(rgba: pixels)
        }
    }

    /// The histogram of `rect` (default: the whole image) of a FloatImage in any colour model,
    /// through straight sRGB RGBA (photocraft reads pixels with `read_rgba_into`).
    public static func compute(_ image: FloatImage, rect: PixelRect? = nil, context: FilterContext, on backend: Backend = .auto) throws -> RgbHistogram {
        try compute(rgba: ToneKit.rgbaPixels(image, rect ?? image.rect, context), on: backend)
    }

    /// Counter layout of the GPU buffer.
    static let gpuCounters = 3 * 256 + 3 + 12

    static func gpu(_ pixels: [SIMD4<Float>]) throws -> RgbHistogram {
        if pixels.isEmpty { return RgbHistogram() }
        guard pixels.count < Int(UInt32.max) else { throw FilterError.invalidInput("more than 2³² pixels") }
        let gpu = try AlgoGPU.shared()
        let dev = gpu.device
        guard let inBuf = pixels.withUnsafeBytes({ dev.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }),
              let outBuf = dev.makeBuffer(length: gpuCounters * 4, options: .storageModeShared) else {
            throw FilterError.gpuUnavailable("histogram buffers")
        }
        memset(outBuf.contents(), 0, gpuCounters * 4)
        let groups = min(max((pixels.count + 1023) / 1024, 1), 1024)
        var params = HistParams(count: UInt32(pixels.count), total: UInt32(groups * 256))
        let pipeline = try gpu.pipeline("pca_tone_rgb_hist")
        try gpu.metal.run(label: "RGB Histogram") { cb in
            guard let enc = cb.makeComputeCommandEncoder() else { throw FilterError.gpuUnavailable("encoder") }
            enc.setComputePipelineState(pipeline)
            enc.setBytes(&params, length: MemoryLayout<HistParams>.stride, index: 0)
            enc.setBuffer(inBuf, offset: 0, index: 1)
            enc.setBuffer(outBuf, offset: 0, index: 2)
            enc.dispatchThreadgroups(MTLSize(width: groups, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
            enc.endEncoding()
        }
        let c = outBuf.contents().assumingMemoryBound(to: UInt32.self)
        var h = RgbHistogram()
        for ch in 0..<3 { for b in 0..<bins { h.channels[ch][b] = UInt64(c[ch * bins + b]) } }
        let o = 3 * bins
        h.samples = UInt64(c[o]); h.transparent = UInt64(c[o + 1]); h.invalid = UInt64(c[o + 2])
        for ch in 0..<3 {
            h.underflow[ch] = UInt64(c[o + 3 + ch]); h.overflow[ch] = UInt64(c[o + 6 + ch])
            h.shadows[ch] = UInt64(c[o + 9 + ch]); h.highlights[ch] = UInt64(c[o + 12 + ch])
        }
        return h
    }

    /// MSL `pca_tone_rgbhist_params`.
    struct HistParams: BitwiseCopyable {
        var count: UInt32
        var total: UInt32
        var pad0: UInt32 = 0
        var pad1: UInt32 = 0
    }
}
