// Port of photocraft-algo (crates/algo/src/artistic_fx.rs `run`, `apply`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// The CPU reference of every Filter Gallery effect: the same formulas, constants, hash seeds and
// operation order as photocraft (per-pixel loops run in parallel; each pixel writes only itself).

import Foundation
import PCFoundation

extension GalleryFXKit {
    /// Runs a stack of effects over `out` (the source covers `out` grown by `reach`).
    static func run(_ effects: [GalleryEffect], _ src: FloatImage, _ out: PixelRect, _ ctx: FilterContext) -> FloatImage {
        let n = src.channels
        let r = src.rect
        let (w, h) = (r.width, r.height)
        var res = src.crop(out)
        if effects.isEmpty || w == 0 || h == 0 || n == 0 { return res }
        var c = [Float](repeating: 0, count: w * h * 3)
        src.data.withUnsafeBufferPointer { sb in
            c.withUnsafeMutableBufferPointer { cb in
                let cs = UnsafeSendable(cb)
                parallelChunks(w * h, minChunk: 1 << 12) { rg in
                    for i in rg {
                        let v = ctx.rgba(UnsafeBufferPointer(rebasing: sb[(i * n)..<((i + 1) * n)]))
                        cs.value[i * 3] = v.x; cs.value[i * 3 + 1] = v.y; cs.value[i * 3 + 2] = v.z
                    }
                }
            }
        }
        var win = Win(r: r, w: w, h: h, c: c)
        for e in effects { apply(e, &win, ctx) }
        let ow = out.width, alpha = ctx.alpha
        let fin = win
        res.data.withUnsafeMutableBufferPointer { db in
            let d = UnsafeSendable(db)
            parallelFor(out.height) { row in
                let y = out.y0 + Int32(row)
                for i in 0..<ow {
                    let x = out.x0 + Int32(i)
                    let px = UnsafeMutableBufferPointer(start: d.value.baseAddress! + (row * ow + i) * n, count: n)
                    let a: Float = alpha ? px[n - 1] : 1
                    let q = fin.at(x, y)
                    ctx.setRGBA(px, SIMD4(clamp01(q.x), clamp01(q.y), clamp01(q.z), a))
                    if alpha { px[n - 1] = a }
                }
            }
        }
        return res
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    static func apply(_ e: GalleryEffect, _ win: inout Win, _ ctx: FilterContext) {
        let g = { (k: String) in e.get(k) }
        let (w, h) = (win.w, win.h)
        let (fg, bg) = (rgb(e.foreground), rgb(e.background))
        switch e.filter {
        // ---------------- Artistic ----------------
        case .coloredPencil:
            let pw = g("pencilWidth")
            let pressure = g("strokePressure") / 15
            let pb = g("paperBrightness")
            let paper = map(bg) { $0 * (0.7 + 0.3 * pb / 50) }
            let l = win.lum()
            let e2 = gradMag(l, w, h)
            win.map { i, x, y, p in
                let d = 1 - l[i]
                let h1 = strokes(x, y, (1, 1), 5 + pw * 3, 0.5 + pw * 0.45, 11)
                let h2 = strokes(x, y, (1, -1), 5 + pw * 3, 0.5 + pw * 0.45, 12)
                let hatch = fmax(h1, h2 * smoothstep(0.3, 0.8, d))
                let cov = clamp01(d * (0.55 + pressure) + e2[i] * 3 - (1 - hatch) * 0.8 + 0.25)
                return mix(paper, map(p) { $0 * 0.88 }, cov)
            }
        case .cutout:
            blur3(&win.c, w, h, cutoutSigma(e))
            let levels = g("numberOfLevels").rounded(.toNearestOrAwayFromZero)
            win.map { _, _, _, p in
                // Flat tones per luminance level, keeping each region's hue.
                let l = fmax(lum(p), 1e-4)
                let k = posterize(l, levels) / l
                return map(p) { posterize(clamp01($0 * k), levels * 2) }
            }
        case .dryBrush, .fresco:
            let fresco = e.filter == .fresco
            kuwahara(&win, 1 + PCAMath.usize(g("brushSize")))
            unsharp(&win, 1, fresco ? 0.9 : 0.5)
            let levels = 3 + g("brushDetail")
            let amp = 0.02 + (g("texture") - 1) * 0.05
            let l = fresco ? gradMag(win.lum(), w, h) : []
            win.map { i, x, y, p0 in
                let n = (hash01(x, y, 0, 21) - 0.5) * amp
                var p = map(p0) { posterize($0, levels) * 0.6 + $0 * 0.4 + n }
                if fresco {
                    let k = 1 - clamp01(l[i] * 2.5) * 0.6
                    p = map(p) { powf(clamp01(($0 - 0.5) * 1.3 + 0.45), 1.15) * k }
                }
                return p
            }
        case .filmGrain:
            let grain = g("grain") / 20
            let (area, inten) = (g("highlightArea"), g("intensity"))
            win.map { _, x, y, p in
                let l = lum(p)
                let n = (hash01(x, y, 0, 31) - 0.5) * grain * 0.5 * (0.3 + 2.8 * l * (1 - l))
                return highlights(map(p) { $0 + n }, l, area, inten)
            }
        case .neonGlow:
            let size = g("glowSize")
            let br = g("glowBrightness") / 50
            let glow = rgb(e.color)
            let l = win.lum()
            var m = size >= 0 ? l : l.map { 1 - $0 }
            blur1(&m, w, h, abs(size) * 0.6 + 0.5)
            win.map { i, _, _, _ in
                let base = mix(fg, bg, l[i])
                let k = clamp01(m[i] * 1.2) * br * 2
                return Px(1 - (1 - base.x) * (1 - clamp01(glow.x * k)), 1 - (1 - base.y) * (1 - clamp01(glow.y * k)),
                          1 - (1 - base.z) * (1 - clamp01(glow.z * k)))
            }
        case .paintDaubs:
            let ty = e.choice("brushType")
            kuwahara(&win, daubsRadius(e))
            let sharp = g("sharpness") / 40
            switch ty {
            case "wideBlurry": blur3(&win.c, w, h, 1.5)
            case "wideSharp": unsharp(&win, 1.5, sharp * 4)
            default: unsharp(&win, 1.2, sharp * 2.5)
            }
            if ["lightRough", "darkRough", "sparkle"].contains(ty) {
                let edges = ty == "sparkle" ? gradMag(win.lum(), w, h) : []
                win.map { i, x, y, p in
                    let n = fbm(Float(x) / 2, Float(y) / 2, 41) - 0.5
                    switch ty {
                    case "lightRough": return map(p) { $0 + fmax(n, 0) * 0.35 }
                    case "darkRough": return map(p) { $0 * (1 - fmax(n, 0) * 0.7) }
                    default:
                        let s = clamp01(edges[i] * 4) * smoothstep(0.75, 0.95, hash01(x, y, 0, 42)) * 0.8
                        return map(p) { $0 + s }
                    }
                }
            }
        case .paletteKnife:
            kuwahara(&win, PCAMath.usize(fmax(g("strokeSize") / 3, 1)))
            let levels = 2 + g("strokeDetail") * 3
            win.map { _, _, _, p in map(p) { posterize($0, levels) * 0.5 + $0 * 0.5 } }
            blur3(&win.c, w, h, g("softness") * 0.5)
        case .plasticWrap:
            let hs = g("highlightStrength") / 20
            var l = win.lum()
            blur1(&l, w, h, plasticSigma(e))
            let (gx, gy) = sobel(l, w, h)
            let (lv, hv) = plasticVectors
            _ = lv
            win.map { i, _, _, p in
                let k: Float = 14
                let n = normalize3(SIMD3(-k * gx[i], -k * gy[i], 1))
                let ndh = fmax(n.x * hv.x + n.y * hv.y + n.z * hv.z, 0)
                let tilt = 1 - n.z
                let spec = powf(ndh, 30) * smoothstep(0.01, 0.12, tilt) + smoothstep(0.25, 0.6, tilt) * 0.25
                return map(p) { $0 * 0.88 + spec * hs * 1.3 }
            }
        case .posterEdges:
            var l = win.lum()
            blur1(&l, w, h, 0.6 + g("edgeThickness") * 0.6)
            let edge = gradMag(l, w, h)
            let inten = g("edgeIntensity") / 10
            let levels = g("posterization") + 2
            win.map { i, _, _, p in
                let ink = smoothstep(0.015, 0.06, edge[i] * (1 + inten * 3)) * (0.55 + inten * 0.45)
                return map(p) { posterize($0, levels) * (1 - ink) }
            }
        case .roughPastels:
            // Chalk strokes up to the right; Stroke Detail keeps more of the image inside them.
            let len = g("strokeLength")
            let det = (g("strokeDetail") - 1) / 19
            if len >= 1 {
                var soft = win.c
                blur3(&soft, w, h, 0.6 + (1 - det) * 1.2)
                let src = Win(r: win.r, w: w, h: h, c: soft)
                win.map { _, x, y, p in
                    let (c, t) = paintStroke(src, x, y, (1, -1), 2 + len, 1.5, 51)
                    // A chalk stroke is a little lighter in its middle, grainy along its length.
                    let n = (strokes(x, y, (1, -1), 2 + len * 0.5, 0.8, 52) - 0.5) * 0.12 + (0.5 - abs(t - 0.5)) * 0.06
                    return map(mix(c, p, det * 0.6)) { $0 + n }
                }
            }
            // Bright areas are thick chalk; in dark ones it's scraped off to show the texture.
            texturize(&win, e.choice("texture"), g("scaling"), g("relief"), e.choice("light"), e.flag("invert")) { 0.15 + 0.85 * (1 - clamp01(lum($0))) }
        case .smudgeStick:
            lineBlur(&win.c, 3, w, h, (1, 1), PCAMath.usize(g("strokeLength") * 1.5))
            let (area, inten) = (g("highlightArea"), g("intensity"))
            win.map { _, _, _, p in
                let l = lum(p)
                return highlights(map(p) { $0 * (0.7 + 0.3 * l) }, l, area, inten)
            }
        case .sponge:
            kuwahara(&win, 1 + PCAMath.usize(g("brushSize")))
            let def = g("definition") / 25
            let sc = 1.5 + g("smoothness") * 0.5
            win.map { _, x, y, p in
                let s = fbm(Float(x) / sc, Float(y) / sc, 61)
                let hole = smoothstep(0.58, 0.75, s)
                return map(p) { clamp01(($0 - 0.5) * (1 + def * 0.6) + 0.5) * (1 - hole * def * 0.4) }
            }
        case .underpainting:
            let orig = win.c
            blur3(&win.c, w, h, 0.5 + g("brushSize") * 0.4)
            orig.withUnsafeBufferPointer { ob in
                win.map { i, _, _, p in saturate(mix(Px(ob[i * 3], ob[i * 3 + 1], ob[i * 3 + 2]), p, 0.8), 1.15) }
            }
            let cov = g("textureCoverage") / 40
            texturize(&win, e.choice("texture"), g("scaling"), g("relief") * (0.5 + cov * 1.5), e.choice("light"), e.flag("invert"))
        case .watercolor:
            kuwahara(&win, watercolorRadius(e))
            let sh = g("shadowIntensity") / 10
            let edge = gradMag(win.lum(), w, h)
            let amp = (g("texture") - 1) * 0.04
            win.map { i, x, y, p in
                let n = (fbm(Float(x) / 3, Float(y) / 3, 71) - 0.5) * amp
                let k = 1 - clamp01(edge[i] * (3 + sh * 8)) * 0.6
                return map(saturate(p, 1.2)) { powf(clamp01($0 * k + n), 1.1 + sh * 0.6) }
            }
        // ---------------- Brush Strokes ----------------
        case .accentedEdges:
            var l = win.lum()
            blur1(&l, w, h, 0.4 + g("smoothness") * 0.3)
            var edge = gradMag(l, w, h)
            blur1(&edge, w, h, g("edgeWidth") * 0.5)
            let eb = g("edgeBrightness") / 50
            win.map { i, _, _, p in
                let k = clamp01(edge[i] * 6)
                return eb >= 0.5 ? map(p) { $0 + (1 - $0) * k * (eb - 0.5) * 2 } : map(p) { $0 * (1 - k * (0.5 - eb) * 2) }
            }
        case .angledStrokes:
            // Light areas are painted in strokes going one way, dark areas the other way.
            let len = fmax(g("strokeLength"), 3)
            let bal = g("directionBalance") / 100
            var soft = win.c
            blur3(&soft, w, h, 0.8)
            let src = Win(r: win.r, w: w, h: h, c: soft)
            let l = src.lum()
            win.map { i, x, y, _ in
                let k = smoothstep(1 - bal - 0.05, 1 - bal + 0.05, l[i])
                let (down, _) = paintStroke(src, x, y, (1, 1), len, 2, 83)
                let (up, _) = paintStroke(src, x, y, (1, -1), len, 2, 84)
                let n = (strokes(x, y, (1, 1), len * 0.5, 0.7, 85) - 0.5) * (1 - k) + (strokes(x, y, (1, -1), len * 0.5, 0.7, 86) - 0.5) * k
                return map(mix(down, up, k)) { $0 + n * 0.1 }
            }
            unsharp(&win, 1, 0.2 + g("sharpness") / 10 * 2.3)
        case .crosshatch:
            let len = g("strokeLength")
            let r = PCAMath.usize(len / 3)
            let st = g("strength")
            win.map { _, x, y, p in
                let n = (hash01(x, y, 0, 81) - 0.5) * 0.12 * st
                return map(p) { $0 + n }
            }
            var a = win.c
            lineBlur(&a, 3, w, h, (1, 1), r)
            lineBlur(&win.c, 3, w, h, (1, -1), r)
            a.withUnsafeBufferPointer { ab in win.map { i, _, _, p in mix(Px(ab[i * 3], ab[i * 3 + 1], ab[i * 3 + 2]), p, 0.5) } }
            unsharp(&win, 1, g("sharpness") / 20 * 3)
        case .darkStrokes:
            let (bal, bi, wi) = (g("balance") / 10, g("blackIntensity") / 10, g("whiteIntensity") / 10)
            let l = win.lum()
            var a = win.c
            lineBlur(&a, 3, w, h, (1, 1), 3)
            lineBlur(&win.c, 3, w, h, (1, -1), 8)
            let t = 0.25 + bal * 0.5
            a.withUnsafeBufferPointer { ab in
                win.map { i, _, _, p in
                    let d = map(Px(ab[i * 3], ab[i * 3 + 1], ab[i * 3 + 2])) { $0 * (1 - bi * 0.85) }
                    let li = map(p) { $0 + (1 - $0) * wi * 0.5 }
                    return mix(d, li, smoothstep(t - 0.1, t + 0.1, l[i]))
                }
            }
        case .inkOutlines:
            let (di, li) = (g("darkIntensity") / 50, g("lightIntensity") / 50)
            let l = win.lum()
            let edge = gradMag(l, w, h)
            lineBlur(&win.c, 3, w, h, (1, 1), PCAMath.usize(g("strokeLength") / 2))
            win.map { i, _, _, p in
                let ink = clamp01(edge[i] * 5) * di * 1.5
                let (lt, dk) = (smoothstep(0.5, 1, l[i]) * li, smoothstep(0.5, 0, l[i]) * di * 0.8)
                return map(p) { ($0 + (1 - $0) * lt) * (1 - dk) * (1 - clamp01(ink)) }
            }
        case .spatter, .sprayedStrokes:
            let rad = g("sprayRadius")
            let sc = e.filter == .spatter ? 0.6 + g("smoothness") * 0.25 : 1.2
            let src = win
            win.map { _, x, y, _ in
                let fx = Float(x) / sc, fy = Float(y) / sc
                let dx = (vnoise(fx, fy, 91) - 0.5) * 2 * rad
                let dy = (vnoise(fx, fy, 92) - 0.5) * 2 * rad
                return src.sample(Float(x) + 0.5 + dx, Float(y) + 0.5 + dy)
            }
            if e.filter == .sprayedStrokes {
                lineBlur(&win.c, 3, w, h, direction(e.choice("strokeDirection")), PCAMath.usize(g("strokeLength") / 2))
            }
        case .sumiE:
            let sw = g("strokeWidth")
            let (pr, con) = (g("strokePressure") / 15, g("contrast") / 40)
            blur3(&win.c, w, h, sw * 0.2)
            lineBlur(&win.c, 3, w, h, (1, 1), PCAMath.usize(sw / 2))
            win.map { _, _, _, p in
                let l = lum(p)
                let ink = powf(smoothstep(0.65, 0.15, l), 1 - pr * 0.5)
                return map(p) { clamp01(($0 - 0.5) * (1 + con) + 0.5) * (1 - ink * 0.9 * (0.5 + con)) }
            }
        // ---------------- Distort ----------------
        case .diffuseGlow:
            let (gr, ga, ca) = (g("graininess") / 10, g("glowAmount") / 20, g("clearAmount") / 20)
            let thr = 0.2 + ca * 0.7
            win.map { _, x, y, p in
                let l = lum(p)
                var m = smoothstep(thr - 0.3, thr + 0.1, l) * ga * 1.4
                if hash01(x, y, 0, 101) < gr * 0.3 * (m + 0.15) { m += 0.5 }
                return mix(p, bg, clamp01(m))
            }
        case .glass:
            let dist = g("distortion")
            let step = 0.5 + g("smoothness") * 0.5
            let kind = textureCode(e.choice("texture"))
            let s = clampf(g("scaling") / 100, 0.5, 2)
            let sign: Float = e.flag("invert") ? -1 : 1
            let mx = dist * 2
            let src = win
            win.map { _, x, y, _ in
                let fx = Float(x), fy = Float(y)
                let gx = texture(kind, fx + step, fy, s) - texture(kind, fx - step, fy, s)
                let gy = texture(kind, fx, fy + step, s) - texture(kind, fx, fy - step, s)
                let dx = clampf(gx * sign * dist * 3, -mx, mx)
                let dy = clampf(gy * sign * dist * 3, -mx, mx)
                return src.sample(fx + 0.5 + dx, fy + 0.5 + dy)
            }
        case .oceanRipple:
            let s = 2 + g("rippleSize") * 1.2
            let mag = g("rippleMagnitude") * 0.9
            let src = win
            win.map { _, x, y, _ in
                let fx = Float(x) / s, fy = Float(y) / s
                let dx = (vnoise(fx, fy, 111) - 0.5) * 2 * mag
                let dy = (vnoise(fx, fy, 112) - 0.5) * 2 * mag
                return src.sample(Float(x) + 0.5 + dx, Float(y) + 0.5 + dy)
            }
        // ---------------- Sketch ----------------
        case .basRelief:
            var l = win.lum()
            let orig = l
            blur1(&l, w, h, basreliefSigma(e))
            let (gx, gy) = sobel(l, w, h)
            let lt = lightDir(e.choice("light"))
            let k = 3 + g("detail") * 0.4
            win.map { i, _, _, _ in
                let t = clamp01(orig[i] * 0.5 + 0.25 + k * -(gx[i] * lt.0 + gy[i] * lt.1))
                return mix(fg, bg, t)
            }
        case .chalkCharcoal:
            let (ca, ch, pr) = (g("charcoalArea") / 20, g("chalkArea") / 20, g("strokePressure") / 5)
            let mid = mix(fg, bg, 0.5)
            win.map { _, x, y, p in
                let l = lum(p)
                let cn = strokes(x, y, (1, 1), 9, 0.9, 121) - 0.5
                let kn = strokes(x, y, (1, -1), 9, 0.9, 122) - 0.5
                let cc = smoothstep(0.25, 0.6, (1 - l) * (0.4 + ca * 1.2) + cn * (0.6 + pr * 0.4) - 0.15)
                let kc = smoothstep(0.25, 0.6, l * (0.4 + ch * 1.2) + kn * (0.6 + pr * 0.4) - 0.15)
                return mix(mix(mid, fg, cc), bg, kc * (1 - cc))
            }
        case .charcoal:
            let (th, det, bal) = (g("charcoalThickness"), g("detail") / 5, g("lightDarkBalance") / 100)
            var l = win.lum()
            blur1(&l, w, h, 1)
            let edge = gradMag(l, w, h)
            win.map { i, x, y, _ in
                let sn = strokes(x, y, (1, 1), 8 + th * 3, 0.6 + th * 0.5, 131) - 0.5
                let cov = smoothstep(1 - bal - 0.2, 1 - bal + 0.2, 1 - l[i] + sn * 0.6) + clamp01(edge[i] * det * 6)
                return mix(bg, fg, clamp01(cov))
            }
        case .chrome:
            let (det, sm) = (g("detail") / 10, g("smoothness") / 10)
            var l = win.lum()
            blur1(&l, w, h, 1 + sm * 4)
            let edge = gradMag(l, w, h)
            win.map { i, _, _, _ in
                let v = 0.5 + 0.5 * sinf((l[i] * (2.5 + det * 3) + edge[i] * 6) * 2 * PCAMath.pi)
                return grey(smoothstep(0.05, 0.95, v))
            }
        case .conteCrayon:
            let (fl, bl) = (g("foregroundLevel") / 15, g("backgroundLevel") / 15)
            let mid = mix(fg, bg, 0.5)
            win.map { _, x, y, p in
                let l = lum(p)
                let sn = strokes(x, y, (1, -1), 7, 1, 141) - 0.5
                let cf = clamp01((0.6 - l) * 2 * fl * 1.4 + sn * 0.5)
                let cb = clamp01((l - 0.4) * 2 * bl * 1.4 - sn * 0.5)
                return mix(mix(mid, fg, cf), bg, cb * (1 - cf))
            }
            texturize(&win, e.choice("texture"), g("scaling"), g("relief"), e.choice("light"), e.flag("invert"))
        case .graphicPen:
            let r = PCAMath.usize(g("strokeLength") / 2)
            let bal = g("lightDarkBalance") / 100
            let l = win.lum()
            var nz = [Float](repeating: 0, count: win.count)
            for i in 0..<win.count {
                let (x, y) = win.xy(i)
                nz[i] = hash01(x, y, 0, 151)
            }
            lineBlur(&nz, 1, w, h, direction(e.choice("strokeDirection")), r)
            let sd = 0.2887 / Float(2 * r + 1).squareRoot()
            win.map { i, _, _, _ in
                let z = (nz[i] - 0.5) / sd
                let t = l[i] + z * 0.16
                return mix(bg, fg, smoothstep(bal + 0.04, bal - 0.04, t))
            }
        case .halftonePattern:
            let size = g("size")
            let con = g("contrast") / 50
            let cell = 3 + size * 2
            var l = win.lum()
            blur1(&l, w, h, 0.5 + size * 0.3)
            let b = ctx.bounds
            let (cx, cy) = (Float(b.x0 &+ b.x1) / 2, Float(b.y0 &+ b.y1) / 2)
            let ty = e.choice("patternType")
            win.map { i, x, y, _ in
                let fx = Float(x) + 0.5, fy = Float(y) + 0.5
                let d = clamp01((1 - l[i] - 0.5) * (1 + con * 3) + 0.5)
                let aa = 1 / cell
                let ink: Float
                switch ty {
                case "circle":
                    let r = ((fx - cx) * (fx - cx) + (fy - cy) * (fy - cy)).squareRoot() / cell
                    let q = abs(fract(r) - 0.5) * 2
                    ink = smoothstep(d + aa, d - aa, q)
                case "line":
                    let q = abs(fract(fy / cell) - 0.5) * 2
                    ink = smoothstep(d + aa, d - aa, q)
                default:
                    let u = fract(fx / cell) - 0.5, v = fract(fy / cell) - 0.5
                    let q = (u * u + v * v).squareRoot() * 2
                    let rr = d.squareRoot() * 1.15
                    ink = smoothstep(rr + aa, rr - aa, q)
                }
                return mix(bg, fg, ink)
            }
        case .notePaper:
            let (bal, gr, rel) = (g("imageBalance") / 50, g("graininess") / 20, g("relief") / 25)
            var l = win.lum()
            blur1(&l, w, h, 1)
            var m = l.map { smoothstep(bal - 0.05, bal + 0.05, $0) }
            blur1(&m, w, h, 1.2)
            let (gx, gy) = sobel(m, w, h)
            let tl = lightDir("topLeft")
            win.map { i, x, y, _ in
                let n = (hash01(x, y, 0, 161) - 0.5) * gr * 0.3
                let f = clampf(shade(gx[i], gy[i], tl, rel * 6), 0, 2)
                return map(mix(fg, bg, m[i])) { ($0 + n) * f }
            }
        case .photocopy:
            let (det, dk) = (g("detail"), g("darkness") / 50)
            let l = win.lum()
            var b = l
            blur1(&b, w, h, 1 + det * 0.5)
            win.map { i, _, _, _ in
                let hp = l[i] - b[i]
                let ink = smoothstep(0, 0.06, -hp * (1 + dk * 8)) + smoothstep(0.35, 0.05, l[i]) * dk * 1.5
                return mix(bg, fg, clamp01(ink))
            }
        case .plaster:
            let bal = g("imageBalance") / 50
            var l = win.lum()
            blur1(&l, w, h, 0.5 + g("smoothness") * 0.8)
            var m = l.map { smoothstep(bal + 0.1, bal - 0.1, $0) }
            blur1(&m, w, h, 1.5)
            let (gx, gy) = sobel(m, w, h)
            let lt = lightDir(e.choice("light"))
            win.map { i, _, _, _ in
                let f = clampf(shade(gx[i], gy[i], lt, 6), 0, 2)
                return map(mix(bg, fg, m[i] * 0.6)) { $0 * f }
            }
        case .reticulation:
            let (den, fl, bl) = (g("density") / 50, g("foregroundLevel") / 50, g("backgroundLevel") / 50)
            let inkC = mix(bg, fg, 0.3 + fl * 0.7)
            let paper = mix(bg, fg, bl * 0.6)
            win.map { _, x, y, p in
                let n = 0.5 * hash01(x, y, 0, 171) + 0.5 * vnoise(Float(x) / 1.8, Float(y) / 1.8, 172)
                let t = (1 - lum(p)) + (n - 0.5) * (0.4 + den * 1.2)
                return mix(paper, inkC, smoothstep(0.45, 0.55, t))
            }
        case .stamp:
            let bal = g("lightDarkBalance") / 50
            var l = win.lum()
            blur1(&l, w, h, 0.3 + g("smoothness") * 0.3)
            win.map { i, _, _, _ in mix(bg, fg, smoothstep(bal + 0.02, bal - 0.02, l[i])) }
        case .tornEdges:
            let (bal, sm, con) = (g("imageBalance") / 50, g("smoothness"), g("contrast"))
            var l = win.lum()
            blur1(&l, w, h, 1)
            let rough = (16 - sm) / 15 * 0.35
            let aa = 0.25 / con
            win.map { i, x, y, _ in
                let t = l[i] + (fbm(Float(x) / 2, Float(y) / 2, 181) - 0.5) * rough
                return mix(bg, fg, smoothstep(bal + aa, bal - aa, t))
            }
        case .waterPaper:
            let fl = g("fiberLength")
            let (br, co) = (g("brightness") / 100, g("contrast") / 100)
            let r = PCAMath.usize(fl / 6)
            lineBlur(&win.c, 3, w, h, (1, 0), r)
            lineBlur(&win.c, 3, w, h, (0, 1), r)
            win.map { _, x, y, p in
                let fib = fmax(strokes(x, y, (1, 0), fl, 1, 191), strokes(x, y, (0, 1), fl, 1, 192))
                return map(p) { ($0 * (0.85 + 0.25 * fib) - 0.5) * (co * 1.6 + 0.2) + 0.5 + (br - 0.5) * 0.8 }
            }
        // ---------------- Stylize ----------------
        case .glowingEdges:
            blur3(&win.c, w, h, 0.3 + g("smoothness") * 0.25)
            var e3 = [Float](repeating: 0, count: win.count * 3)
            for c in 0..<3 {
                let plane = (0..<win.count).map { win.c[$0 * 3 + c] }
                for (i, v) in gradMag(plane, w, h).enumerated() { e3[i * 3 + c] = v }
            }
            blur3(&e3, w, h, g("edgeWidth") * 0.4)
            let k = 2 + g("edgeBrightness") * 1.2
            e3.withUnsafeBufferPointer { eb in
                win.map { i, _, _, _ in Px(clamp01(eb[i * 3] * k), clamp01(eb[i * 3 + 1] * k), clamp01(eb[i * 3 + 2] * k)) }
            }
        // ---------------- Texture ----------------
        case .craquelure:
            let (sp, dep, bri) = (g("crackSpacing"), g("crackDepth") / 10, g("crackBrightness") / 10)
            let cell = sp * 1.3 + 1
            let width = 0.8 + dep * 0.8
            @inline(__always) func crack(_ x: Float, _ y: Float) -> Float {
                let (d1, d2, _) = voronoi(x, y, cell, 201)
                return 1 - smoothstep(0, width, d2 - d1)
            }
            let tl = lightDir("topLeft")
            win.map { _, x, y, p in
                let fx = Float(x) + 0.5, fy = Float(y) + 0.5
                let c0 = crack(fx, fy)
                let gx = crack(fx + 1, fy) - c0, gy = crack(fx, fy + 1) - c0
                let f = clampf(shade(-gx, -gy, tl, dep * 2), 0, 2)
                return map(p) { $0 * (0.55 + bri * 0.5) * (1 - c0 * dep * 0.6) * f }
            }
        case .grain:
            let (it, co) = (g("intensity") / 100, g("contrast") / 100)
            let ty = e.choice("grainType")
            win.map { _, x, y, p in
                @inline(__always) func hc(_ c: UInt32) -> Float { hash01(x, y, c, 211) - 0.5 }
                let q: Px
                switch ty {
                case "soft": q = Px(p.x + hc(0) * it * 0.4, p.y + hc(1) * it * 0.4, p.z + hc(2) * it * 0.4)
                case "sprinkles": q = hash01(x, y, 3, 211) < it * 0.15 ? bg : p
                case "clumped":
                    let n = vnoise(Float(x) / 2, Float(y) / 2, 212) - 0.5
                    q = map(p) { $0 + n * it * 1.2 }
                case "contrasty":
                    let n = hc(4)
                    q = map(p) { ($0 - 0.5) * (1 + it * 2) + 0.5 + n * it * 0.5 }
                case "enlarged":
                    let fx = Float(x) / 3, fy = Float(y) / 3
                    q = Px(p.x + (vnoise(fx, fy, 213) - 0.5) * it, p.y + (vnoise(fx, fy, 214) - 0.5) * it, p.z + (vnoise(fx, fy, 215) - 0.5) * it)
                case "stippled":
                    let st = lum(p) > hash01(x, y, 5, 211) ? bg : fg
                    q = mix(p, st, 0.3 + it * 0.7)
                case "horizontal":
                    let n = vnoise(Float(x) / 25, Float(y), 216) - 0.5
                    q = map(p) { $0 + n * it }
                case "vertical":
                    let n = vnoise(Float(x), Float(y) / 25, 217) - 0.5
                    q = map(p) { $0 + n * it }
                case "speckle": q = hash01(x, y, 6, 211) < it * 0.1 ? mix(p, fg, 0.85) : p
                default: q = Px(p.x + hc(0) * it * 0.8, p.y + hc(1) * it * 0.8, p.z + hc(2) * it * 0.8)
                }
                return map(q) { ($0 - 0.5) * (0.5 + co) + 0.5 }
            }
        case .mosaicTiles:
            let (ts, gw, lg) = (g("tileSize"), g("groutWidth"), g("lightenGrout") / 10)
            @inline(__always) func edge(_ x: Float, _ y: Float) -> Float {
                let jx = x + (vnoise(x / ts * 0.7, y / ts * 0.7, 221) - 0.5) * ts * 0.3
                let jy = y + (vnoise(x / ts * 0.7, y / ts * 0.7, 222) - 0.5) * ts * 0.3
                let u = euclidMod(jx, ts), v = euclidMod(jy, ts)
                return fmin(fmin(u, ts - u), fmin(v, ts - v))
            }
            win.map { _, x, y, p in
                let fx = Float(x) + 0.5, fy = Float(y) + 0.5
                let de = edge(fx, fy)
                let grout = smoothstep(gw * 0.5 + 0.7, gw * 0.5 - 0.3, de)
                @inline(__always) func hgt(_ xx: Float, _ yy: Float) -> Float { smoothstep(gw * 0.5, gw * 0.5 + 2.5, edge(xx, yy)) }
                let s = (hgt(fx - 1, fy - 1) - hgt(fx + 1, fy + 1)) * 0.35
                let l = lum(p)
                let gc = grey(clamp01(l * 0.5 + lg * 0.45))
                return mix(map(p) { $0 * (1 + s) }, gc, grout)
            }
        case .patchwork:
            let size = patchSize(e)
            let rel = g("relief") / 25
            let src = win
            @inline(__always) func hv(_ x: Float, _ y: Float) -> Float {
                let bx = PCAMath.i32((x / size).rounded(.down)), by = PCAMath.i32((y / size).rounded(.down))
                let u = euclidMod(x, size), v = euclidMod(y, size)
                let bevel = smoothstep(0, 1.5, fmin(fmin(u, size - u), fmin(v, size - v)))
                return hash01(bx, by, 0, 231) * bevel
            }
            win.map { _, x, y, _ in
                let fx = Float(x) + 0.5, fy = Float(y) + 0.5
                let bx = (fx / size).rounded(.down), by = (fy / size).rounded(.down)
                let c = src.at(PCAMath.i32((bx + 0.5) * size), PCAMath.i32((by + 0.5) * size))
                let s = (hv(fx - 1, fy - 1) - hv(fx + 1, fy + 1)) * rel * 1.5
                return map(c) { $0 * (1 + s) }
            }
        case .stainedGlass:
            let cell = glassCell(e)
            let bt = g("borderThickness")
            let li = g("lightIntensity") / 10
            let b = ctx.bounds
            let (cx, cy) = (Float(b.x0 &+ b.x1) / 2, Float(b.y0 &+ b.y1) / 2)
            let half = fmax(Float(max(b.width, b.height)) / 2, 1)
            let src = win
            win.map { _, x, y, _ in
                let fx = Float(x) + 0.5, fy = Float(y) + 0.5
                let (d1, d2, p) = voronoi(fx, fy, cell, 241)
                let border = smoothstep(bt * 0.5 + 0.6, bt * 0.5 - 0.4, (d2 - d1) * 0.5)
                let dn = fmin(((fx - cx) * (fx - cx) + (fy - cy) * (fy - cy)).squareRoot() / half, 1)
                let col = map(src.at(PCAMath.i32(p.0), PCAMath.i32(p.1))) { $0 * (1 + li * 0.6 * (1 - dn)) }
                return mix(col, fg, border)
            }
        case .texturizer:
            texturize(&win, e.choice("texture"), g("scaling"), g("relief"), e.choice("light"), e.flag("invert"))
        }
    }

    /// Plastic Wrap's light and half vectors.
    static let plasticVectors: (SIMD3<Float>, SIMD3<Float>) = {
        let lv = normalize3(SIMD3(-0.45, -0.65, 1))
        return (lv, normalize3(SIMD3(lv.x, lv.y, lv.z + 1)))
    }()
}
