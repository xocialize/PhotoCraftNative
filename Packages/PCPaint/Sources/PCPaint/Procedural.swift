// Port of photocraft-paint (crates/paint/src/procedural.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Procedural (generated, deterministic) texture patterns and sampled tips for the built-in
// presets: seeded value noise and simple geometry, no bundled brush files.

import Foundation

public enum Procedural {
    @inline(__always) static func smooth(_ t: Float) -> Float { t * t * (3 - 2 * t) }
    @inline(__always) static func fract(_ v: Float) -> Float { v - v.rounded(.towardZero) }

    /// Tileable value noise with `period` lattice cells over the tile.
    static func valueNoise(_ x: Float, _ y: Float, _ period: Int32, _ salt: UInt64) -> Float {
        let x0 = x.rounded(.down), y0 = y.rounded(.down)
        let tx = smooth(x - x0), ty = smooth(y - y0)
        let xi = asI32(x0), yi = asI32(y0)
        func h(_ i: Int32, _ j: Int32) -> Float { PaintRNG.hash2(remEuclid(i, period), remEuclid(j, period), salt) }
        let a = h(xi, yi) + (h(xi &+ 1, yi) - h(xi, yi)) * tx
        let b = h(xi, yi &+ 1) + (h(xi &+ 1, yi &+ 1) - h(xi, yi &+ 1)) * tx
        return a + (b - a) * ty
    }

    /// Tileable fractal noise in 0…1 (`cells` lattice cells across at the base octave).
    static func fbm(_ x: Float, _ y: Float, _ size: Float, _ cells: Int32, _ octaves: UInt32, _ salt: UInt64) -> Float {
        var sum: Float = 0, amp: Float = 1, norm: Float = 0, c = cells
        for o in 0..<octaves {
            sum += valueNoise(x / size * Float(c), y / size * Float(c), c, salt &+ UInt64(o) &* 7919) * amp
            norm += amp
            amp *= 0.5
            c &*= 2
        }
        return sum / norm
    }

    /// Generate a seamless pattern tile.
    public static func pattern(_ style: PatternStyle, _ size: UInt32, _ seed: UInt32) -> PatternImage {
        let n = Int(min(max(size, 8), 1024))
        let s = Float(n)
        let salt = UInt64(seed) &* 0x0100_0000_01B3 &+ 17
        var data = [Float](repeating: 0, count: n * n)
        for y in 0..<n {
            for x in 0..<n {
                let fx = Float(x) + 0.5, fy = Float(y) + 0.5
                let v: Float
                switch style {
                case .noise:
                    v = fbm(fx, fy, s, 8, 4, salt)
                case .paper:
                    let base = fbm(fx, fy, s, 16, 4, salt)
                    let grain = PaintRNG.hash2(Int32(x), Int32(y), salt ^ 0x55)
                    v = clampR((base - 0.5) * 2.2 + 0.5 + (grain - 0.5) * 0.35, 0, 1)
                case .canvas:
                    // Over/under weave: threads every 8 px, alternating which direction is on top.
                    let period: Float = 8
                    let cx = asI32((fx / period).rounded(.down)), cy = asI32((fy / period).rounded(.down))
                    let u = fract(fx / period), vv = fract(fy / period)
                    let warp = sinf(Float.pi * u)
                    let weft = sinf(Float.pi * vv)
                    let top = (cx + cy) % 2 == 0 ? warp : weft
                    v = clampR(0.25 + 0.65 * top + (PaintRNG.hash2(Int32(x), Int32(y), salt) - 0.5) * 0.15, 0, 1)
                case .dots:
                    let period: Float = 8
                    let u = fract(fx / period) - 0.5, vv = fract(fy / period) - 0.5
                    let d = (u * u + vv * vv).squareRoot()
                    v = 1 - smooth(clampR((0.35 - d) / 0.1 + 0.5, 0, 1))
                }
                data[y * n + x] = v
            }
        }
        return PatternImage(width: n, height: n, data: data)
    }

    /// A chalk/charcoal tip: a disc with a ragged edge and grainy interior.
    public static func chalkTip(_ n: UInt32, _ seed: UInt32) -> GrayTile {
        let salt = UInt64(seed) + 101
        let c = Float(n) / 2
        return GrayTile(width: n, height: n) { x, y in
            let dx = Float(x) + 0.5 - c, dy = Float(y) + 0.5 - c
            let r = (dx * dx + dy * dy).squareRoot() / c
            let ang = atan2f(dy, dx)
            let edge = 0.8 + 0.15 * valueNoise((ang + Float.pi) * 3, 0.5, 19, salt)
            let inside = clampR((edge - r) * 8, 0, 1)
            let grain = PaintRNG.hash2(Int32(x), Int32(y), salt)
            return inside * (grain < 0.2 ? 0.2 : 0.7 + 0.3 * grain)
        }
    }

    /// A spatter tip: a cluster of round droplets of different sizes.
    public static func spatterTip(_ n: UInt32, _ seed: UInt32, _ drops: UInt32) -> GrayTile {
        let salt = UInt64(seed) + 202
        let s = Float(n)
        let blobs: [(Float, Float, Float)] = (0..<drops).map { i in
            let a = PaintRNG.hash2(Int32(i), 0, salt) * 2 * Float.pi
            let d = PaintRNG.hash2(Int32(i), 1, salt).squareRoot() * 0.38 * s
            let h2 = PaintRNG.hash2(Int32(i), 2, salt)
            let r = (0.03 + 0.09 * (h2 * h2)) * s
            return (s / 2 + cosf(a) * d, s / 2 + sinf(a) * d, r)
        }
        return GrayTile(width: n, height: n) { x, y in
            let px = Float(x) + 0.5, py = Float(y) + 0.5
            return blobs.reduce(Float(0)) { acc, b in
                let d = ((px - b.0) * (px - b.0) + (py - b.1) * (py - b.1)).squareRoot()
                return maxR(acc, clampR(b.2 + 0.5 - d, 0, 1))
            }
        }
    }

    /// A bristle tip: parallel hair streaks of varying density inside an ellipse.
    public static func bristleTip(_ n: UInt32, _ seed: UInt32) -> GrayTile {
        let salt = UInt64(seed) + 303
        let c = Float(n) / 2
        return GrayTile(width: n, height: n) { x, y in
            let dx = (Float(x) + 0.5 - c) / c, dy = (Float(y) + 0.5 - c) / c
            let r = (dx * dx + (dy * 1.8) * (dy * 1.8)).squareRoot()
            if r > 1 { return 0 }
            let hair = PaintRNG.hash2(0, asI32(Float(y) / 1.5), salt)
            let density: Float = hair < 0.25 ? 0 : 0.5 + 0.5 * hair
            let r2 = r * r
            return density * (1 - r2 * r2)
        }
    }

    /// A charcoal tip: a squat ellipse of broken horizontal streaks with a gritty edge.
    public static func charcoalTip(_ n: UInt32, _ seed: UInt32) -> GrayTile {
        let salt = UInt64(seed) + 404
        let c = Float(n) / 2
        return GrayTile(width: n, height: n) { x, y in
            let dx = (Float(x) + 0.5 - c) / c, dy = (Float(y) + 0.5 - c) / c
            let r = (dx * dx + (dy * 1.6) * (dy * 1.6)).squareRoot()
            let edge = 0.85 + 0.15 * valueNoise(dx * 6 + 9, dy * 6 + 9, 64, salt)
            if r > edge { return 0 }
            // Streaks: per-row density modulated along x so they break up.
            let row = PaintRNG.hash2(0, Int32(y), salt)
            let along = valueNoise(Float(x) / 6, Float(y) / 1.5, 1 << 12, salt ^ 0x77)
            let grit = PaintRNG.hash2(Int32(x), Int32(y), salt ^ 0x13)
            let v = (0.35 + 0.65 * row) * (0.4 + 0.6 * along) * (grit < 0.15 ? 0.2 : 1)
            return v * clampR((edge - r) * 6, 0, 1)
        }
    }

    /// A leaf: a pointed lens shape with a lighter midrib, stem towards −x.
    public static func leafTip(_ n: UInt32) -> GrayTile {
        let c = Float(n) / 2
        return GrayTile(width: n, height: n) { x, y in
            let u = (Float(x) + 0.5 - c) / c, v = (Float(y) + 0.5 - c) / c
            let t = clampR((u + 1) / 2, 0, 1)
            let half = 0.42 * sinf(Float.pi * t) * (1 - 0.25 * t)
            let inside = clampR((half - abs(v)) * c, 0, 1)
            let rib = 1 - 0.45 * (1 - clampR(abs(v) * c / 1.2, 0, 1))
            let veins = 1 - 0.2 * (1 - clampR(abs(fract(u * 7 - abs(v) * 5) - 0.5) * 8, 0, 1))
            let stem: Float = (u < -0.75 && abs(v) * c < 0.9) ? 1 : 0
            return maxR(inside * rib * veins, stem)
        }
    }

    /// Grass: a tuft of tapered, slightly curved blades rising from the bottom edge.
    public static func grassTip(_ n: UInt32, _ seed: UInt32, _ blades: UInt32) -> GrayTile {
        let salt = UInt64(seed) + 505
        let s = Float(n)
        let bl: [(Float, Float, Float, Float)] = (0..<blades).map { i in
            let base = (0.3 + 0.4 * PaintRNG.hash2(Int32(i), 0, salt)) * s
            let height = (0.55 + 0.42 * PaintRNG.hash2(Int32(i), 1, salt)) * s
            let lean = (PaintRNG.hash2(Int32(i), 2, salt) - 0.5) * 0.9
            let width = (0.025 + 0.025 * PaintRNG.hash2(Int32(i), 3, salt)) * s
            return (base, height, lean, width)
        }
        return GrayTile(width: n, height: n) { x, y in
            let px = Float(x) + 0.5, py = Float(y) + 0.5
            let up = s - py
            return bl.reduce(Float(0)) { acc, b in
                let (base, height, lean, width) = b
                if up < 0 || up > height { return acc }
                let t = up / height
                let cx = base + lean * height * t * t
                let w = width * (1 - t) + 0.3
                return maxR(acc, clampR(w - abs(px - cx), 0, 1))
            }
        }
    }

    /// A sea sponge: a disc riddled with holes of different sizes.
    public static func spongeTip(_ n: UInt32, _ seed: UInt32) -> GrayTile {
        let salt = UInt64(seed) + 606
        let c = Float(n) / 2
        return GrayTile(width: n, height: n) { x, y in
            let dx = Float(x) + 0.5 - c, dy = Float(y) + 0.5 - c
            let r = (dx * dx + dy * dy).squareRoot() / c
            let edge = 0.78 + 0.2 * valueNoise((atan2f(dy, dx) + Float.pi) * 2.5, 0.5, 16, salt)
            let disc = clampR((edge - r) * 6, 0, 1)
            let pores = fbm(Float(x), Float(y), Float(n), 6, 3, salt)
            return disc * clampR((pores - 0.42) * 6, 0, 1)
        }
    }

    /// A four-point sparkle with a soft glow.
    public static func starTip(_ n: UInt32) -> GrayTile {
        let c = Float(n) / 2
        return GrayTile(width: n, height: n) { x, y in
            let u = abs((Float(x) + 0.5 - c) / c), v = abs((Float(y) + 0.5 - c) / c)
            func ray(_ a: Float, _ b: Float) -> Float { maxR((1 - a) * (1 - minR(b / (0.08 * (1 - a) + 0.005), 1)), 0) }
            let g = maxR(1 - (u * u + v * v).squareRoot() * 2.5, 0)
            return minR(maxR(maxR(ray(u, v), ray(v, u)), g * g), 1)
        }
    }

    /// A rake: a row of separate round bristles of slightly different sizes.
    public static func rakeTip(_ n: UInt32, _ seed: UInt32, _ bristles: UInt32) -> GrayTile {
        let salt = UInt64(seed) + 707
        let s = Float(n)
        let k = max(bristles, 1)
        let dots: [(Float, Float, Float)] = (0..<k).map { i in
            let x = s * (Float(i) + 0.5) / Float(k)
            let y = s / 2 + (PaintRNG.hash2(Int32(i), 0, salt) - 0.5) * s * 0.08
            let r = s / Float(k) * (0.22 + 0.18 * PaintRNG.hash2(Int32(i), 1, salt))
            return (x, y, r)
        }
        return GrayTile(width: n, height: n) { x, y in
            let px = Float(x) + 0.5, py = Float(y) + 0.5
            return dots.reduce(Float(0)) { acc, d in
                let dd = ((px - d.0) * (px - d.0) + (py - d.1) * (py - d.1)).squareRoot()
                return maxR(acc, clampR(d.2 + 0.5 - dd, 0, 1) * 0.9)
            }
        }
    }
}
