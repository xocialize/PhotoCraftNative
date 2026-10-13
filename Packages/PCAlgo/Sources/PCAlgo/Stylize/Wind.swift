// Port of photocraft-algo (crates/algo/src/stylize2.rs `wind`/`wind_direct`, stylize2/wind.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Filter › Stylize › Wind. The CPU reference is photocraft's per-pixel search (`wind_direct`,
// which its scatter path `wind::streaks` reproduces bit for bit) with each row's luma computed
// once; the GPU runs the same search per pixel over a luma texture.

import PCFoundation

/// Wind method (photocraft `WindMethod`).
public enum WindMethod: String, Codable, Sendable, Hashable, CaseIterable {
    case wind, blast, stagger
}

/// Filter › Stylize › Wind: streaks trail downwind from edges (Blast: longer and denser);
/// Stagger shifts random row segments along the wind.
public struct Wind: Filter, Hashable {
    public var method: WindMethod
    public var fromRight: Bool
    public var seed: UInt32
    public init(method: WindMethod = .wind, fromRight: Bool = true, seed: UInt32 = 0) {
        self.method = method; self.fromRight = fromRight; self.seed = seed
    }
    public var label: String { "Wind" }

    /// Longest streak (or stagger shift) of a method, px (photocraft `wind_reach`).
    static func reach(_ m: WindMethod) -> Float {
        switch m { case .wind: 16; case .blast: 40; case .stagger: 12 }
    }
    public func halo(bounds: PixelRect) -> Halo { StylizeKit.reach(Self.reach(method)) }
    /// Stagger moves whole pixels by a channel-independent hash; streaks weigh luma edges.
    public var gpuChannels: GPUChannels { method == .stagger ? .perChannel : .joint }
    public func supportsGPU(_ ctx: FilterContext, channels: Int) -> Bool {
        method == .stagger || StylizeKit.supportsFxLuma(ctx, channels: channels)
    }

    /// The stagger shift of row segment containing `x` (photocraft's Stagger branch).
    @inline(__always)
    static func staggerShift(_ x: Int32, _ y: Int32, _ d: Int32, _ lmax: Int32, _ seed: UInt32) -> Int32 {
        let segLen = 8 + StylizeKit.i32(hash01(0, y, 41, seed) * 32)
        let phase = StylizeKit.i32(hash01(1, y, 42, seed) * Float(segLen))
        let seg = StylizeKit.divEuclid(x &* d &+ phase, segLen)
        let h = hash01(seg, y, 43, seed)
        return StylizeKit.i32(h * h * Float(lmax))
    }

    public func cpu(_ src: FloatImage, out: PixelRect, ctx: FilterContext) -> FloatImage {
        let n = src.channels
        var res = src.crop(out)
        if out.isEmpty || n == 0 { return res }
        let lmax = Int32(Self.reach(method))
        // Streaks move downwind: from the left they extend to the right (+x).
        let d: Int32 = fromRight ? -1 : 1
        let ow = out.width, seed = self.seed, method = self.method
        let strength: Float = method == .blast ? 8 : 4
        // Luma of every source the row searches read: x − d·k and x − d·(k + 1), k ≤ lmax.
        let lx0 = out.x0 - lmax - 1, lw = ow + 2 * Int(lmax) + 2
        src.data.withUnsafeBufferPointer { sb in
            let s = StyView(sb, src)
            res.withStyOut { dv in
                parallelFor(out.height) { row in
                    let y = out.y0 + Int32(row)
                    if method == .stagger {
                        for i in 0..<ow {
                            let x = out.x0 + Int32(i)
                            let shift = Self.staggerShift(x, y, d, lmax, seed)
                            s.read(x - d &* shift, y, dv.value + (row * ow + i) * n)
                        }
                        return
                    }
                    withStyScratch(n) { tmp in
                        var lum = [Float](repeating: 0, count: lw)
                        for j in 0..<lw {
                            s.read(lx0 + Int32(j), y, tmp.baseAddress!)
                            lum[j] = ctx.luma(UnsafeBufferPointer(tmp))
                        }
                        for i in 0..<ow {
                            let x = out.x0 + Int32(i)
                            var best: (Float, Int32) = (0, x)
                            for k in 1...lmax {
                                let sx = x - d * k
                                // Each source pixel starts a streak of random length; only edges start visible ones.
                                let h = hash01(sx, y, 44, seed)
                                let len = StylizeKit.fmax(h * h * Float(lmax), 1)
                                if Float(k) > len { continue }
                                let e = StylizeKit.fmin(abs(lum[Int(sx - lx0)] - lum[Int(sx - d - lx0)]) * strength, 1)
                                let wgt = e * (1 - Float(k) / (len + 1))
                                if wgt > best.0 { best = (wgt, sx) }
                            }
                            if best.0 > 0 {
                                s.read(best.1, y, tmp.baseAddress!)
                                let o = (row * ow + i) * n
                                for c in 0..<n { dv.value[o + c] += (tmp[c] - dv.value[o + c]) * best.0 }
                            }
                        }
                    }
                }
            }
        }
        return res
    }

    public func encodeGPU(_ pass: GPUPass) throws {
        let out = pass.out
        let lmax = Int32(Self.reach(method))
        let d: Int32 = fromRight ? -1 : 1
        let lumRect = PixelRect(x0: out.x0 - lmax - 1, y0: out.y0, x1: out.x1 + lmax + 1, y1: out.y1)
        let p = WindParams(lumOrigin: SIMD2(lumRect.x0, lumRect.y0), lumSize: SIMD2(Int32(lumRect.width), Int32(lumRect.height)),
                           lmax: lmax, d: d, seed: seed, strength: method == .blast ? 8 : 4,
                           luma: StylizeKit.fxLumaCode(pass.ctx) ?? 1)
        if method == .stagger {
            try pass.dispatchOut("pca_sty_wind_stagger", params: p)
            return
        }
        let lum = try pass.texture(lumRect)
        try pass.dispatch("pca_sty_wind_luma", params: p, textures: [pass.src, lum], width: lumRect.width, height: lumRect.height)
        try pass.dispatchOut("pca_sty_wind", params: p, textures: [pass.src, lum, pass.dst])
    }
}

/// MSL `pca_sty_wind_params`.
private struct WindParams: BitwiseCopyable {
    var lumOrigin: SIMD2<Int32>
    var lumSize: SIMD2<Int32>
    var lmax: Int32
    var d: Int32
    var seed: UInt32
    var strength: Float
    var luma: Int32
    var pad0: Int32 = 0
    var pad1: Int32 = 0
    var pad2: Int32 = 0
}
