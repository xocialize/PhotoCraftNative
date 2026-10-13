// The model-free tiers PCIntelligence assembles from the fleet's Tier-0 Kits, for the jobs whose
// Kit ships the parts but not the job:
//   • denoise / JPEG artifact smoothing from RestoreTier0's guided filter and Immerkaer noise
//     estimate (ForgeRestoreKit names no denoise job at Tier 0; its guided filter is the
//     edge-preserving smoother the job needs);
//   • white balance from LightTier0 (shades-of-grey p = 6, Bradford adaptation, in linear light);
//   • SDR → HDR from LightTier0 (deband → BT.2408 direct mapping → dither, decoded to linear light).
// Part of the AI tier for photocraft gap G15 (Neural Filters, Camera Raw style auto white balance),
// MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import LightTier0
import PCFoundation
import RestoreTier0

// MARK: - Denoise (RestoreTier0)

enum ClassicalDenoise {
    struct Result {
        var rgba: [SIMD4<Float>]
        var sigmaBefore: Float
        var sigmaAfter: Float
    }

    /// Edge-preserving denoise of encoded RGB: a self-guided filter on luma (radius 2–4) and on
    /// chroma (twice that radius), with ε = (k·σ)² from the Immerkaer σ of the luma, floored so JPEG
    /// blocking (structured, low σ) still smooths. `strength` 0…1 sets k, the floor, the radius and
    /// the mix. Alpha is untouched.
    static func denoise(_ px: [SIMD4<Float>], width: Int, height: Int, strength: Float) -> Result {
        let s = min(max(strength, 0), 1)
        let n = width * height
        var yP = [Float](repeating: 0, count: n), cb = yP, cr = yP
        for i in 0..<n {
            let p = px[i]
            let y = 0.299 * p.x + 0.587 * p.y + 0.114 * p.z
            yP[i] = y; cb[i] = (p.z - y) * 0.564; cr[i] = (p.x - y) * 0.713
        }
        let sigma = NoiseEstimate.immerkaer(yP, width: width, height: height)
        let k = 1.5 + s
        let floor: Float = 0.004 + 0.02 * s
        let eps = pow(k * max(sigma, floor), 2)
        let r = 2 + Int((s * 2).rounded())
        let filter: any EdgeAwareFilter = GuidedFilterMetal.shared ?? GuidedFilter()
        let yB = filter.base(of: yP, width: width, height: height, radius: r, epsilon: eps)
        let cbB = filter.base(of: cb, width: width, height: height, radius: 2 * r, epsilon: 4 * eps)
        let crB = filter.base(of: cr, width: width, height: height, radius: 2 * r, epsilon: 4 * eps)
        let mix = 0.5 + 0.5 * s
        var out = px
        var yOut = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let y = yP[i] + (yB[i] - yP[i]) * mix
            let b = cb[i] + (cbB[i] - cb[i]) * mix
            let rr = cr[i] + (crB[i] - cr[i]) * mix
            yOut[i] = y
            out[i] = SIMD4(y + 1.403 * rr, y - 0.344 * b - 0.714 * rr, y + 1.773 * b, px[i].w)
        }
        let after = NoiseEstimate.immerkaer(yOut, width: width, height: height)
        return Result(rgba: out, sigmaBefore: sigma, sigmaAfter: after)
    }
}

// MARK: - White balance (LightTier0)

enum ClassicalWhiteBalance {
    struct Result {
        var rgba: [SIMD4<Float>]
        var illuminant: IlluminantEstimator.Illuminant
        var temperature: IlluminantEstimator.Temperature
    }

    /// Estimates the illuminant from the encoded-sRGB pixels whose `weight` is above 0.5 (opaque
    /// and selected), adapts every pixel to neutral in linear light (Bradford), and re-encodes.
    /// Integer documents clamp on write; float documents keep values outside 0…1.
    static func balance(_ px: [SIMD4<Float>], weight: [Float]?) -> Result {
        func lin(_ v: Float) -> Float { v < 0 ? -ColorConvert.srgbToLinear(-v) : ColorConvert.srgbToLinear(v) }
        func enc(_ v: Float) -> Float { v < 0 ? -ColorConvert.linearToSRGB(-v) : ColorConvert.linearToSRGB(v) }
        let linear = px.map { SIMD3(lin($0.x), lin($0.y), lin($0.z)) }
        var sample: [SIMD3<Float>] = []
        sample.reserveCapacity(linear.count)
        for i in linear.indices where px[i].w > 0.5 && (weight?[i] ?? 1) > 0.5 { sample.append(linear[i]) }
        let illuminant = IlluminantEstimator.estimate(linearRGB: sample)
        let matrix = ChromaticAdaptation.transform(from: illuminant)
        let adapted = ChromaticAdaptation.apply(matrix, to: linear)
        var out = px
        for i in px.indices { out[i] = SIMD4(enc(adapted[i].x), enc(adapted[i].y), enc(adapted[i].z), px[i].w) }
        return Result(rgba: out, illuminant: illuminant, temperature: IlluminantEstimator.temperature(of: illuminant))
    }
}

// MARK: - SDR → HDR (LightTier0)

enum ClassicalHDRExpansion {
    struct Result {
        /// Linear light, 1.0 = BT.2408 HDR reference white (203 cd/m²); alpha as the source.
        var rgba: [SIMD4<Float>]
        var peakNits: Double
    }

    /// Runs LightTier0's mandated chain (deband in the SDR gamma domain → BT.2408 direct mapping to
    /// PQ → dither once) on each colour plane, then decodes the PQ signal to absolute luminance and
    /// expresses it relative to the HDR reference white.
    static func expand(_ px: [SIMD4<Float>], width: Int, height: Int, diffuseWhiteNits: Double,
                       deband: Bool, dither: Bool) -> Result {
        var options = InverseToneMapping.Options.default
        options.diffuseWhiteNits = diffuseWhiteNits
        options.target = .pq
        options.deband = deband
        if !dither { options.ditherAmplitude = 0 }
        let ref = TransferFunctions.hdrReferenceWhiteNits
        var planes: [[Float]] = []
        for c in 0..<3 {
            let plane = px.map { min(max($0[c], 0), 1) }
            planes.append(InverseToneMapping.expand(plane, width: width, height: height, options: options))
        }
        var out = px
        var peak = 0.0
        for i in px.indices {
            var v = SIMD3<Float>()
            for c in 0..<3 {
                let nits = PQ.decode(signal: Double(planes[c][i]))
                peak = max(peak, nits)
                v[c] = Float(nits / ref)
            }
            out[i] = SIMD4(v, px[i].w)
        }
        return Result(rgba: out, peakNits: peak)
    }
}
