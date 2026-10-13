// Port of photocraft-algo (crates/algo/src/stack.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Image stack statistics (Layer › Smart Objects › Stack Mode): a per-pixel, per-channel statistic
// across N aligned straight-RGBA images. Only samples with alpha > 0 contribute; the output alpha
// is the largest input alpha. Population moments; skewness/kurtosis standardised and scaled into
// 0…1; entropy is the Shannon entropy (bits) of the 8-bit values over log2(N).

import Foundation
import Metal
import PCFoundation

public enum StackStat: String, Codable, Sendable, Hashable, CaseIterable {
    case entropy, kurtosis, maximum, mean, median, minimum, range, skewness, standardDeviation, summation, variance
    var code: UInt32 { UInt32(StackStat.allCases.firstIndex(of: self)!) }
}

public enum Stack {
    /// Most layers the Metal kernel gathers per pixel (more run on the CPU).
    public static let maxGPULayers = 64

    /// photocraft `stat`: the statistic of `v` (reordered by the median).
    static func stat(_ v: inout [Float], _ s: StackStat) -> Float {
        if v.isEmpty { return 0 }
        let n = Float(v.count)
        var sum: Float = 0
        for x in v { sum += x }
        let mean = sum / n
        func m(_ k: Int) -> Float {
            var a: Float = 0
            for x in v {
                let d = x - mean
                switch k { case 2: a += d * d; case 3: a += d * d * d; default: let d2 = d * d; a += d2 * d2 }
            }
            return a / n
        }
        switch s {
        case .mean: return mean
        case .summation: return sum
        case .minimum: return v.reduce(Float.greatestFiniteMagnitude) { Float.minimum($0, $1) }
        case .maximum: return v.reduce(-Float.greatestFiniteMagnitude) { Float.maximum($0, $1) }
        case .range: return v.reduce(-Float.greatestFiniteMagnitude) { Float.maximum($0, $1) } - v.reduce(Float.greatestFiniteMagnitude) { Float.minimum($0, $1) }
        case .median:
            v.sort { MedianKit.key($0) < MedianKit.key($1) }
            let k = v.count
            return k % 2 == 1 ? v[k / 2] : (v[k / 2 - 1] + v[k / 2]) / 2
        case .variance: return m(2)
        case .standardDeviation: return m(2).squareRoot()
        case .skewness:
            let sd = m(2).squareRoot()
            return sd < 1e-6 ? 0.5 : clampf(m(3) / (sd * sd * sd) / 4 + 0.5, 0, 1)
        case .kurtosis:
            let vv = m(2)
            return vv < 1e-12 ? 0 : clampf(m(4) / (vv * vv) / 10, 0, 1)
        case .entropy:
            if v.count < 2 { return 0 }
            // photocraft sums a HashMap's counts in its (random) iteration order; here in level order.
            var counts = [Int](repeating: 0, count: 256)
            for x in v { counts[Int((clampf(x, 0, 1) * 255).rounded(.toNearestOrAwayFromZero))] += 1 }
            var h: Float = 0
            for c in counts where c > 0 { let p = Float(c) / n; h += -p * log2f(p) }
            return h / log2f(n)
        }
    }

    /// Combines `layers` (each `count` straight RGBA pixels) with statistic `s` (photocraft `combine`).
    public static func combine(_ layers: [[SIMD4<Float>]], _ s: StackStat, on backend: Backend = .auto) throws -> [SIMD4<Float>] {
        let len = layers.map(\.count).max() ?? 0
        let gpu = backend != .cpu && layers.count <= maxGPULayers && layers.allSatisfy { $0.count == len } && len > 0
        if gpu, let g = try? AlgoGPU.shared() { return try combineGPU(g, layers, s, len) }
        if backend == .gpu { throw FilterError.gpuUnsupported("Stack: \(layers.count) layers") }
        var out = [SIMD4<Float>](repeating: .zero, count: len)
        out.withUnsafeMutableBufferPointer { ob in
            let os = UnsafeSendable(ob)
            parallelChunks(len, minChunk: 4096) { r in
                var samples: [[Float]] = [[], [], []]
                for i in r {
                    for c in 0..<3 { samples[c].removeAll(keepingCapacity: true) }
                    var alpha: Float = 0
                    for l in layers where i < l.count && l[i].w > 0 {
                        for c in 0..<3 { samples[c].append(l[i][c]) }
                        alpha = Float.maximum(alpha, l[i].w)
                    }
                    if alpha <= 0 { continue }
                    var o = SIMD4<Float>(0, 0, 0, alpha)
                    for c in 0..<3 { o[c] = stat(&samples[c], s) }
                    os.value[i] = o
                }
            }
        }
        return out
    }

    struct Params: BitwiseCopyable { var count: UInt32; var layers: UInt32; var stat: UInt32; var pad: UInt32 = 0 }

    static func combineGPU(_ gpu: AlgoGPU, _ layers: [[SIMD4<Float>]], _ s: StackStat, _ len: Int) throws -> [SIMD4<Float>] {
        let bytes = len * 16
        let input = try gpu.stagingBuffer(length: bytes * layers.count), output = try gpu.stagingBuffer(length: bytes)
        defer { gpu.returnStaging(input); gpu.returnStaging(output) }
        let ip = input.contents().assumingMemoryBound(to: SIMD4<Float>.self)
        for (k, l) in layers.enumerated() { l.withUnsafeBufferPointer { (ip + k * len).update(from: $0.baseAddress!, count: len) } }
        try gpu.metal.run(label: "Stack") { cb in
            let pass = try GPUPass.synthetic(gpu, cb, rect: PixelRect(x: 0, y: 0, width: len, height: 1))
            try pass.dispatch("pca_misc_stack", params: Params(count: UInt32(len), layers: UInt32(layers.count), stat: s.code),
                              textures: [], buffers: [input, output], width: len, height: 1, threadgroup: (256, 1))
        }
        let op = output.contents().assumingMemoryBound(to: SIMD4<Float>.self)
        return Array(UnsafeBufferPointer(start: op, count: len))
    }
}
