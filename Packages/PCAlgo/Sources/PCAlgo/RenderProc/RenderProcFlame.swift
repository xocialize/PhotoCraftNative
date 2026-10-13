// Port of photocraft-algo (crates/algo/src/render2.rs: `FlameType`, `FlameStyle`, `FlameShape`, `FlameSpec`, `flame_colour`, `draw_flame`, `flame`, `default_flame_path`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Filter › Render › Flame: turbulent flame strands along a path (or candles), as primitives.

import Foundation
import PCFoundation

/// Flame placement (Photoshop's six flame types).
public enum FlameType: String, Codable, Sendable, Hashable, CaseIterable {
    /// One flame whose spine is the path (path start = flame base).
    case oneFlameAlongPath
    /// Flames at `interval` along the path, rising from its left side.
    case multipleFlamesAlongPath
    /// Flames at `interval` along the path, pointing along the path's direction.
    case multipleFlamesPathDirections
    /// Like `multipleFlamesAlongPath` with strongly varying lengths.
    case multipleFlamesVariousLength
    /// A candle flame at the start of each subpath.
    case candleLight
    /// Flames at `interval` along the path, all pointing at `angle`.
    case multipleFlamesOneDirection
}

/// Overall motion of the flame lines.
public enum FlameStyle: String, Codable, Sendable, Hashable, CaseIterable { case normal, violent, flat }

/// How the flame lines converge towards the tip.
public enum FlameShape: String, Codable, Sendable, Hashable, CaseIterable { case parallel, toCenter, spread, oval, pointed }

/// Flame options (Photoshop's Flame dialog, Basic + Advanced) — photocraft `FlameSpec`; every
/// field defaults when missing from JSON.
public struct FlameSpec: Codable, Sendable, Hashable {
    public var flameType: FlameType = .oneFlameAlongPath
    /// Flame length in px (1–1000).
    public var length: Float = 150
    public var randomizeLength = false
    /// Flame width in px (1–1000).
    public var width: Float = 40
    /// Direction for `multipleFlamesOneDirection` (degrees, 0 = up, clockwise).
    public var angle: Float = 0
    /// Spacing between flames along the path in px (1–1000).
    public var interval: Float = 60
    /// Spread the flames evenly so a closed path loops seamlessly.
    public var adjustIntervalForLoops = true
    /// A custom flame colour (straight sRGB RGBA); nil = natural flame colours.
    public var color: SIMD4<Float>?
    /// 0–100.
    public var turbulent: Float = 25
    /// 0–100.
    public var jag: Float = 25
    /// 0–100 %.
    public var opacity: Float = 75
    /// Flame lines (complexity) 1–100.
    public var flameLines: Float = 20
    /// 0–100: how unevenly the lines start along the flame.
    public var flameBottomAlignment: Float = 20
    public var flameStyle: FlameStyle = .normal
    public var flameShape: FlameShape = .parallel
    public var randomizeShapes = false
    /// Arrangement seed.
    public var seed: UInt32 = 0
    /// 0 (draft) … 4 (fine): segments per flame line.
    public var quality: UInt32 = 2

    public init() {}

    enum CodingKeys: String, CodingKey {
        case flameType, length, randomizeLength, width, angle, interval, adjustIntervalForLoops, color, turbulent, jag, opacity,
             flameLines, flameBottomAlignment, flameStyle, flameShape, randomizeShapes, seed, quality
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = FlameSpec()
        flameType = try c.decodeIfPresent(FlameType.self, forKey: .flameType) ?? d.flameType
        length = try c.decodeIfPresent(Float.self, forKey: .length) ?? d.length
        randomizeLength = try c.decodeIfPresent(Bool.self, forKey: .randomizeLength) ?? d.randomizeLength
        width = try c.decodeIfPresent(Float.self, forKey: .width) ?? d.width
        angle = try c.decodeIfPresent(Float.self, forKey: .angle) ?? d.angle
        interval = try c.decodeIfPresent(Float.self, forKey: .interval) ?? d.interval
        adjustIntervalForLoops = try c.decodeIfPresent(Bool.self, forKey: .adjustIntervalForLoops) ?? d.adjustIntervalForLoops
        color = try c.decodeIfPresent(SIMD4<Float>.self, forKey: .color)
        turbulent = try c.decodeIfPresent(Float.self, forKey: .turbulent) ?? d.turbulent
        jag = try c.decodeIfPresent(Float.self, forKey: .jag) ?? d.jag
        opacity = try c.decodeIfPresent(Float.self, forKey: .opacity) ?? d.opacity
        flameLines = try c.decodeIfPresent(Float.self, forKey: .flameLines) ?? d.flameLines
        flameBottomAlignment = try c.decodeIfPresent(Float.self, forKey: .flameBottomAlignment) ?? d.flameBottomAlignment
        flameStyle = try c.decodeIfPresent(FlameStyle.self, forKey: .flameStyle) ?? d.flameStyle
        flameShape = try c.decodeIfPresent(FlameShape.self, forKey: .flameShape) ?? d.flameShape
        randomizeShapes = try c.decodeIfPresent(Bool.self, forKey: .randomizeShapes) ?? d.randomizeShapes
        seed = try c.decodeIfPresent(UInt32.self, forKey: .seed) ?? d.seed
        quality = try c.decodeIfPresent(UInt32.self, forKey: .quality) ?? d.quality
    }
}

extension RenderProc {
    /// Builds flame primitives; `paths` are flattened polylines in document pixels
    /// (photocraft `flame`).
    public static func flame(_ spec: FlameSpec, paths: [[SIMD2<Float>]]) -> [Prim] {
        var out: [Prim] = []
        var rng = Rng(seed: spec.seed, salt: 0xF1A3)
        let length = clampf(spec.length, 1, 1000)
        let width = clampf(spec.width, 1, 1000)
        let interval = clampf(spec.interval, 1, 1000)
        func pickLen(_ rng: inout Rng, _ v: Float) -> Float {
            if spec.randomizeLength || v > 0 {
                return length * rng.range(1 - Float.maximum(v, 0.4), 1 + Float.maximum(v, 0.4) * 0.5)
            }
            return length
        }
        for path in paths where !path.isEmpty {
            let spine = RenderProcKit.Spine(path)
            let total = spine.len
            switch spec.flameType {
            case .oneFlameAlongPath where path.count >= 2 && total >= 1:
                RenderProcKit.drawFlame(&out, spine, width, spec, &rng)
            case .candleLight, .oneFlameAlongPath:
                // A candle: a short teardrop rising straight up from the start.
                let base = path[0]
                let h = Float.minimum(length, 400)
                let candle = RenderProcKit.Spine([base, SIMD2(base.x, base.y - h)])
                var c = spec
                c.flameShape = .oval
                c.turbulent = spec.turbulent * 0.3
                c.jag = spec.jag * 0.2
                RenderProcKit.drawFlame(&out, candle, Float.maximum(width * 0.6, 4), c, &rng)
                let core = RenderProcKit.flameColour(0.05, spec.color)
                out.append(Prim.ellipse(SIMD2(base.x, base.y - h * 0.28), Float.maximum(width * 0.12, 1.5), h * 0.22, 0,
                                        SIMD4(core.x, core.y, core.z, 0.9 * clampf(spec.opacity, 0, 100) / 100), SIMD4(core.x, core.y, core.z, 0))
                    .withSoft(2).additive())
            default:
                let closed = path.count > 2 && abs(path[0].x - path[path.count - 1].x) < 1 && abs(path[0].y - path[path.count - 1].y) < 1
                let count: Int
                if spec.adjustIntervalForLoops && closed {
                    let c = (total / interval).rounded(.toNearestOrAwayFromZero)
                    count = c.isFinite && c > 1 ? min(PCAMath.usize(c), 2048) : 1
                } else {
                    let c = (total / interval).rounded(.down)
                    count = c.isFinite && c >= 0 ? min(PCAMath.usize(c) + 1, 2048) : 1
                }
                let step = spec.adjustIntervalForLoops && closed ? total / Float(count) : interval
                for k in 0..<count {
                    if out.count >= 65536 { break }
                    let s = Float(k) * step
                    let (p, d) = spine.at(s)
                    let dir: SIMD2<Float>
                    switch spec.flameType {
                    case .multipleFlamesPathDirections: dir = d
                    case .multipleFlamesOneDirection:
                        let a = PCAMath.radians(spec.angle)
                        dir = SIMD2(sinf(a), -cosf(a))
                    // Left of the path direction (up for a left-to-right path).
                    default: dir = SIMD2(d.y, -d.x)
                    }
                    let v: Float = spec.flameType == .multipleFlamesVariousLength ? 0.7 : 0
                    let l = pickLen(&rng, v)
                    let fl = RenderProcKit.Spine([p, SIMD2(p.x + dir.x * l, p.y + dir.y * l)])
                    RenderProcKit.drawFlame(&out, fl, width, spec, &rng)
                }
            }
        }
        return out
    }

    /// The path Flame uses when the document has none: a gentle arc across the lower part of the
    /// canvas (photocraft `default_flame_path`).
    public static func defaultFlamePath(_ canvas: PixelRect) -> [SIMD2<Float>] {
        let w = Float(canvas.width), h = Float(canvas.height)
        return (0...32).map { k in
            let t = Float(k) / 32
            return SIMD2(Float(canvas.x0) + w * (0.15 + 0.7 * t), Float(canvas.y0) + h * (0.8 - 0.08 * sinf(PCAMath.pi * t)))
        }
    }
}

extension RenderProcKit {
    /// Natural flame colour at position `t` along the flame (0 = base, 1 = tip), or the custom
    /// colour's core → colour → rim ramp (photocraft `flame_colour`).
    static func flameColour(_ t: Float, _ custom: SIMD4<Float>?) -> SIMD4<Float> {
        let a = powf(1 - t, 0.7) * 0.9 + 0.1 * (1 - t)
        if let c = custom {
            // Hot near-white core → the colour → a darker rim.
            let core = SIMD3(c.x * 0.4 + 0.6, c.y * 0.4 + 0.6, c.z * 0.4 + 0.6)
            let rim = SIMD3(c.x * 0.6, c.y * 0.6, c.z * 0.6)
            let k = clampf(t, 0, 1)
            let rgb: SIMD3<Float>
            if k < 0.35 {
                let u = k / 0.35
                rgb = SIMD3(core.x + (c.x - core.x) * u, core.y + (c.y - core.y) * u, core.z + (c.z - core.z) * u)
            } else {
                let u = (k - 0.35) / 0.65
                rgb = SIMD3(c.x + (rim.x - c.x) * u, c.y + (rim.y - c.y) * u, c.z + (rim.z - c.z) * u)
            }
            return SIMD4(rgb, a * c.w)
        }
        let stops: [(Float, SIMD3<Float>)] = [(0, SIMD3(1, 0.98, 0.85)), (0.2, SIMD3(1, 0.86, 0.35)), (0.45, SIMD3(1, 0.55, 0.08)),
                                              (0.75, SIMD3(0.9, 0.25, 0.02)), (1, SIMD3(0.6, 0.08, 0))]
        let k = clampf(t, 0, 1)
        var rgb = stops[4].1
        for i in 0..<4 where k <= stops[i + 1].0 {
            let (t0, c0) = stops[i], (t1, c1) = stops[i + 1]
            let u = (k - t0) / (t1 - t0)
            rgb = SIMD3(c0.x + (c1.x - c0.x) * u, c0.y + (c1.y - c0.y) * u, c0.z + (c1.z - c0.z) * u)
            break
        }
        return SIMD4(rgb, a)
    }

    /// One flame: its spine (base → tip), width and random stream (photocraft `draw_flame`).
    static func drawFlame(_ out: inout [RenderProc.Prim], _ spine: Spine, _ width: Float, _ spec: FlameSpec, _ rng: inout RenderProc.Rng) {
        typealias Prim = RenderProc.Prim
        let len = spine.len
        if len < 1 { return }
        let lines = PCAMath.usize((clampf(spec.flameLines, 1, 100) * 0.6 + 3).rounded(.toNearestOrAwayFromZero))
        let segs = min(max([6, 10, 16, 24, 36][Int(min(spec.quality, 4))], PCAMath.usize(len / 12)), 160)
        var turb = clampf(spec.turbulent, 0, 100) / 100, jag = clampf(spec.jag, 0, 100) / 100
        switch spec.flameStyle {
        case .violent:
            turb = Float.minimum(turb * 1.8 + 0.2, 2)
            jag = Float.minimum(jag * 1.8 + 0.15, 2)
        case .flat:
            turb *= 0.35
            jag *= 0.35
        case .normal: break
        }
        let shape = spec.randomizeShapes ? FlameShape.allCases[Int(rng.nextU64() % 5)] : spec.flameShape
        let opacity = clampf(spec.opacity, 0, 100) / 100
        let half = Float.maximum(width, 1) / 2
        let seed = rng.nextU64()
        // The whole flame sways; each line adds its own flicker on top.
        func sway(_ u: Float) -> Float { turb * half * 1.6 * fbm1(u * 1.7, seed ^ 0x5A5A) * powf(u, 1.4) }
        // A soft additive body glow along the spine.
        for k in 0..<6 {
            let u = Float(k) / 6 * 0.75 + 0.05
            let (p, d) = spine.at(u * len)
            let o = sway(u)
            let c = flameColour(u, spec.color)
            let r = half * (1.25 - u) + 2
            out.append(Prim.ellipse(SIMD2(p.x - d.y * o, p.y + d.x * o), r, r * 1.2, atan2f(d.y, d.x),
                                    SIMD4(c.x, c.y, c.z, 0.16 * opacity), SIMD4(c.x, c.y * 0.6, c.z * 0.3, 0))
                .withSoft(Float.maximum(r, 2)).additive())
        }
        let lineR = clampf(half / Float(lines) * 2.2, 0.8, 10)
        for li in 0..<lines {
            let lane: Float = lines == 1 ? 0 : Float(li) / Float(lines - 1) * 2 - 1
            let lseed = seed ^ (UInt64(li) &* 0x51_7CC1_B727_220A)
            let start = (clampf(spec.flameBottomAlignment, 0, 100) / 100) * rng.f() * 0.4
            // Outer lines are shorter, giving the flame its tongue shape.
            let reach = (1 - 0.55 * powf(abs(lane), 1.5)) * rng.range(0.7, 1)
            let end = clampf(start + reach * (1 - start), start + 0.05, 1)
            let lr = lineR * rng.range(0.6, 1.3)
            var prev: (SIMD2<Float>, Float, Float)?
            for k in 0...segs {
                let u = start + (end - start) * Float(k) / Float(segs)
                let s = u * len
                let (p0, d) = spine.at(s)
                let nx = -d.y, ny = d.x
                let spread: Float
                switch shape {
                case .parallel: spread = 1 - 0.6 * u
                case .toCenter: spread = 1 - u
                case .spread: spread = 1 + u
                case .oval: spread = sinf(PCAMath.pi * (0.15 + 0.85 * u)) * 1.3
                case .pointed: spread = (1 - u) * (1 - u)
                }
                let flick = turb * half * 0.5 * fbm1(s / (len * 0.2 + 6) + Float(li) * 0.37, lseed) * u
                    + jag * half * 0.25 * noise1(s / 5, lseed ^ 0x77) * u
                let off = lane * half * spread + sway(u) + flick
                let p = SIMD2(p0.x + nx * off, p0.y + ny * off)
                let r = lr * (1 - u * 0.75)
                // Lines fade out towards their own tip.
                let fadeT = clampf((u - start) / Float.maximum(end - start, 1e-3), 0, 1)
                if let (q, rq, uq) = prev {
                    // Fade in over the first tenth (a soft base) and out towards the line's tip.
                    func f(_ c: SIMD4<Float>, _ uu: Float, _ t: Float) -> SIMD4<Float> {
                        SIMD4(c.x, c.y, c.z, c.w * opacity * (1 - t * t * t) * clampf((uu - start) / 0.08, 0, 1).squareRoot())
                    }
                    out.append(Prim.capsule(q, p, rq, r, f(flameColour(uq, spec.color), uq, fadeT), f(flameColour(u, spec.color), u, fadeT))
                        .withSoft(1 + lr * 0.6).lightened())
                }
                prev = (p, r, u)
            }
        }
    }
}
