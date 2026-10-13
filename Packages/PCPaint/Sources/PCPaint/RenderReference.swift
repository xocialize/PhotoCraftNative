// Port of photocraft-paint (crates/paint/src/render_reference.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// The frozen scalar rasteriser: a pixel oracle for the computed-tip fast path (`rasterizeRound`)
// and the reference the Metal dab kernel is parity-tested against. It is kept exactly as
// photocraft froze it, including one difference from the production path: per-tip texturing here
// combines with `maskCombine` (the production rasteriser uses `textureCombine`, which differs only
// for the Subtract, Color Dodge/Burn and Height modes; the parity tests use Multiply).

import Foundation
import PCFoundation

extension BrushContext {
    public func rasterizeReference(_ d: Dab, dual: Bool, rect: PixelRect, _ out: inout [Float], depth: inout [Float], withDepth: Bool) {
        let w = rect.width, h = rect.height
        out.removeAll(keepingCapacity: true)
        out.append(contentsOf: repeatElement(0, count: w * h))
        if withDepth {
            depth.removeAll(keepingCapacity: true)
            depth.append(contentsOf: repeatElement(0, count: w * h))
        }
        let b = brush
        let hardness = dual ? b.dualBrush.hardness : b.hardness
        let mips = dual ? dualTip : tip
        let aliased = b.aliased && !dual
        let wet = b.wetEdges && !dual && !withDepth
        let noise = b.noise && !dual
        let texTip = !dual && b.texture.enabled && b.texture.eachTip && texture != nil
        let (cx, cy) = aliased ? gridCenter(d.center.x, d.center.y, 2 * d.radius) : (Float(d.center.x), Float(d.center.y))
        let sn = sinf(d.angle), cs = cosf(d.angle)
        let fx: Float = d.flipX ? -1 : 1, fy: Float = d.flipY ? -1 : 1
        let proj: (Float, Float, Float)? = (!dual && d.projScale < 0.999)
            ? (cosf(d.projAngle), sinf(d.projAngle), 1 / maxR(d.projScale, 0.05) - 1) : nil
        let r = d.radius
        let ro = minR(maxR(d.roundness, 0.5 / r), 1)
        let rm = maxR(r * ro, 0.5)
        let reach2 = (rm + 0.5) * (rm + 0.5)
        var level = 0
        var invScale: Float = 1, tw: Float = 1, th: Float = 1
        if let m = mips {
            let l0 = m.levels[0]
            let big = Float(max(l0.w, l0.h))
            level = m.levelFor(2 * r * maxR(ro, 0.25))
            invScale = big / (2 * r)
            tw = Float(l0.w); th = Float(l0.h)
        }
        func toTip(_ dx: Float, _ dy: Float) -> (Float, Float) {
            var ux = dx, uy = -dy
            if let (ax, ay, k) = proj {
                let t = (ux * ax + uy * ay) * k
                ux += t * ax
                uy += t * ay
            }
            return ((ux * cs + uy * sn) * fx, (-ux * sn + uy * cs) * fy)
        }
        let small = mips == nil && !aliased && rm < smallTipRadius
        let smallReach2 = (rm + 0.75) * (rm + 0.75)
        for yy in 0..<h {
            let y = rect.y0 + Int32(yy)
            let dy = Float(y) + 0.5 - cy
            for xx in 0..<w {
                let x = rect.x0 + Int32(xx)
                let dx = Float(x) + 0.5 - cx
                let (u, v) = toTip(dx, dy)
                var val: Float
                let rn: Float
                if aliased && b.square {
                    if abs(dx) >= r || abs(dy) >= r { continue }
                    val = 1; rn = 0
                } else if mips == nil && small {
                    let d2 = (u * ro) * (u * ro) + v * v
                    if d2 >= smallReach2 { continue }
                    var sum: Float = 0
                    for sy in subpixel {
                        for sx in subpixel {
                            let (su, sv) = toTip(dx + sx, dy + sy)
                            let sd = ((su * ro) * (su * ro) + sv * sv).squareRoot()
                            let inside = clampR((rm - sd) * 4 + 0.5, 0, 1)
                            if inside > 0 { sum += inside * tipFalloff(minR(sd, rm), rm, hardness) }
                        }
                    }
                    val = sum / Float(subpixel.count * subpixel.count)
                    rn = d2.squareRoot() / rm
                } else if let m = mips {
                    let px = u * invScale + tw / 2, py = -(v / ro) * invScale + th / 2
                    if px < -1 || py < -1 || px > tw + 1 || py > th + 1 { continue }
                    let s = m.sampleClamped(level, px / tw, py / th)
                    val = aliased ? (s >= 0.5 ? 1 : 0) : s
                    rn = 1 - s
                } else {
                    let d2 = (u * ro) * (u * ro) + v * v
                    if d2 >= reach2 { continue }
                    let dd = d2.squareRoot()
                    val = aliased ? (dd <= rm ? 1 : 0) : dabCoverage(dd, rm, hardness)
                    rn = dd / rm
                }
                if val <= 0 { continue }
                if noise && val < 1 {
                    let n = PaintRNG.hash2(x, y, noiseSalt)
                    let hard: Float = n < val ? 1 : 0
                    val += (hard - val) * 0.7
                }
                if texTip { val = maskCombine(b.texture.mode, val, textureAt(x, y), d.depth) }
                if wet { val *= wetFactor(rn) }
                if withDepth { depth[yy * w + xx] = clampR(1 - rn, 0, 1) }
                out[yy * w + xx] = val * d.alpha
            }
        }
    }
}
