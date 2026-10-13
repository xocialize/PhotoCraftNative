// Port of photocraft-algo (crates/algo/src/vectorscope.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// A bounded hue/saturation distribution of RGBA colours (already in the chosen RGB space).

import Metal
import PCFoundation

public struct Vectorscope: Sendable, Equatable {
    public static let hues = 128
    public static let saturations = 64
    public var counts: [UInt32] = [UInt32](repeating: 0, count: hues * saturations)
    public var samples: UInt64 = 0
    public init() {}

    /// Hue as turns and saturation in 0…1; achromatic pixels have zero saturation.
    public static func hueSaturation(_ c: SIMD3<Float>) -> (Float, Float) {
        let r = c.x, g = c.y, b = c.z
        let high = Float.maximum(Float.maximum(r, g), b), low = Float.minimum(Float.minimum(r, g), b)
        let delta = high - low
        if delta <= Float.ulpOfOne || high <= 0 { return (0, 0) }
        let h: Float = high == r ? (g - b) / delta : high == g ? 2 + (b - r) / delta : 4 + (r - g) / delta
        return (euclidMod(h / 6, 1), delta / high)
    }

    /// photocraft `Vectorscope::from_rgba`: transparent and non-finite pixels are skipped.
    public static func fromRGBA(_ pixels: [SIMD4<Float>], on backend: Backend = .auto) throws -> Vectorscope {
        if backend != .cpu, !pixels.isEmpty, let gpu = try? AlgoGPU.shared() { return try fromRGBAGPU(gpu, pixels) }
        if backend == .gpu { throw FilterError.gpuUnavailable("Vectorscope") }
        var out = Vectorscope()
        for p in pixels {
            if p.w <= 0 || !(p.x.isFinite && p.y.isFinite && p.z.isFinite && p.w.isFinite) { continue }
            let (h, s) = hueSaturation(SIMD3(clampf(p.x, 0, 1), clampf(p.y, 0, 1), clampf(p.z, 0, 1)))
            let hue = min(Int(h * Float(hues)), hues - 1)
            let sat = min(Int((s * Float(saturations - 1)).rounded(.toNearestOrAwayFromZero)), saturations - 1)
            out.counts[hue * saturations + sat] &+= 1
            out.samples &+= 1
        }
        return out
    }

    struct Params: BitwiseCopyable { var count: UInt32; var pad0: UInt32 = 0; var pad1: UInt32 = 0; var pad2: UInt32 = 0 }

    static func fromRGBAGPU(_ gpu: AlgoGPU, _ pixels: [SIMD4<Float>]) throws -> Vectorscope {
        let input = try gpu.stagingBuffer(length: pixels.count * 16), bins = try gpu.stagingBuffer(length: (hues * saturations + 1) * 4)
        defer { gpu.returnStaging(input); gpu.returnStaging(bins) }
        pixels.withUnsafeBytes { input.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        memset(bins.contents(), 0, (hues * saturations + 1) * 4)
        try gpu.metal.run(label: "Vectorscope") { cb in
            let pass = try GPUPass.synthetic(gpu, cb, rect: PixelRect(x: 0, y: 0, width: pixels.count, height: 1))
            try pass.dispatch("pca_misc_vectorscope", params: Params(count: UInt32(pixels.count)), textures: [], buffers: [input, bins],
                              width: pixels.count, height: 1, threadgroup: (256, 1))
        }
        var out = Vectorscope()
        let b = bins.contents().assumingMemoryBound(to: UInt32.self)
        for i in 0..<(hues * saturations) { out.counts[i] = b[i] }
        out.samples = UInt64(b[hues * saturations])
        return out
    }
}
