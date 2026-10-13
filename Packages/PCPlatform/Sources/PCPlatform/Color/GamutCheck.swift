// Out-of-gamut test against a proof profile (View ▸ Gamut Warning).
// Replaces photocraft-cms (crates/cms/src/gamut.rs) with ColorSync conversions sampled on a grid.
// Port of its API shape, MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// A colour is out of gamut when sending it to the proof device (relative colorimetric, clipped) and
// back to Lab moves it by more than the threshold (ΔE76) — photocraft's definition, kept so warnings
// agree. The ΔE is tabulated over the source device space (33³ for 3 channels, 17⁴ for 4, 256 for 1)
// from two batched ColorSync conversions; ColorSync's own `kColorSyncTransformGamutCheck` gives a
// 1-bit answer with an undocumented tolerance, so it is not used.

import Foundation

public final class GamutCheck: @unchecked Sendable {
    /// photocraft's default threshold (ΔE76).
    public static let defaultThreshold: Float = 4.0

    public let source: ICCProfile
    public let proof: ICCProfile
    public var threshold: Float
    public let grid: GridLUT

    public init(source: ICCProfile, proof: ICCProfile, threshold: Float = GamutCheck.defaultThreshold) throws {
        self.source = source; self.proof = proof; self.threshold = threshold
        let lab = BuiltinProfile.labD50.profile
        let direct = try ColorTransform(source: source, destination: lab, options: .init(intent: .relativeColorimetric))
        let toProof = try ColorTransform(source: source, destination: proof, options: .init(intent: .relativeColorimetric))
        let back = try ColorTransform(source: proof, destination: lab, options: .init(intent: .relativeColorimetric))
        let n = source.channels
        let size = n == 1 ? 256 : (n == 4 ? 17 : 33)
        grid = GridLUT.sample(inputs: n == 1 ? 1 : (n == 4 ? 4 : 3), size: size, outputs: 1) { pts, count in
            let a = direct.convert(pts, pixelCount: count)
            var p = toProof.convert(pts, pixelCount: count)
            for i in p.indices { p[i] = min(max(p[i], 0), 1) }
            let b = back.convert(p, pixelCount: count)
            var de = [Float](repeating: 0, count: count)
            for i in 0..<count {
                let la = LabEncoding.colorSync.decode(SIMD3(a[i * 3], a[i * 3 + 1], a[i * 3 + 2]))
                let lb = LabEncoding.colorSync.decode(SIMD3(b[i * 3], b[i * 3 + 1], b[i * 3 + 2]))
                de[i] = Float(ColorMath.deltaE76(la, lb))
            }
            return de
        }
    }

    /// ΔE76 between the colour and its proof round trip (interpolated).
    public func deltaE(_ px: [Float]) -> Float { grid.eval(px)[0] }

    public func isOutOfGamut(_ px: [Float]) -> Bool { deltaE(px) > threshold }

    /// A 0/1 warning mask over a raster in the source model (1 = out of gamut).
    public func mask(_ r: RasterBuffer) -> [Float] {
        let f = r.floats(), ch = r.format.channels, n = source.channels
        var out = [Float](repeating: 0, count: r.width * r.height)
        var px = [Float](repeating: 0, count: n)
        for i in 0..<out.count {
            for k in 0..<n { px[k] = f[i * ch + k] }
            out[i] = isOutOfGamut(px) ? 1 : 0
        }
        return out
    }
}
