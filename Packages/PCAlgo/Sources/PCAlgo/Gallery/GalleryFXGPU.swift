// Port of photocraft-algo (crates/algo/src/artistic_fx.rs `run`, `apply`; fxutil.rs buffer blurs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// The Filter Gallery's Metal path. The working window is a float4 texture (sRGB, 0) covering the
// source window; each effect is a short chain of passes producing the next window texture:
// planes (luma, steps, noise), Sobel, f64-faithful line / box / Gaussian blurs (MSL
// `pca_gfx_line_ff`: float-float sums, so posterize and Kuwahara thresholds see the CPU's
// numbers), Kuwahara, unsharp, texturize, and one per-pixel kernel per effect
// (GalleryFXEffects.metal). Glowing Edges reuses the standalone filter's kernels and blurs, so
// it matches GlowingEdges exactly on both backends.

import Metal
import PCFoundation

extension GalleryFXKit {
    /// MSL `pca_gfx_params`.
    struct GParams: BitwiseCopyable {
        var winOrigin: SIMD2<Int32>
        var winSize: SIMD2<Int32>
        var fg = SIMD4<Float>(repeating: 0)
        var bg = SIMD4<Float>(repeating: 0)
        var color = SIMD4<Float>(repeating: 0)
        var v0 = SIMD4<Float>(repeating: 0)
        var v1 = SIMD4<Float>(repeating: 0)
        var v2 = SIMD4<Float>(repeating: 0)
        var v3 = SIMD4<Float>(repeating: 0)
        var i0: Int32 = 0
        var i1: Int32 = 0
        var i2: Int32 = 0
        var i3: Int32 = 0
        var bc = SIMD2<Float>(repeating: 0)
        var halfB: Float = 1
        var pad0: Int32 = 0
    }

    /// MSL `pca_gfx_line_params`.
    struct LineParams: BitwiseCopyable {
        var size: SIMD2<Int32>
        var d: SIMD2<Int32>
        var radius: Int32
        var segment: Int32
        var normHi: Float
        var normLo: Float
        var lines: Int32
        var pad0: Int32 = 0
        var pad1: Int32 = 0
        var pad2: Int32 = 0
    }

    /// MSL `pca_sty_glow_params` (the standalone Glowing Edges' Sobel kernel).
    struct GlowParams: BitwiseCopyable {
        var winOrigin: SIMD2<Int32>
        var winSize: SIMD2<Int32>
        var gain: Float
        var pad0: Int32 = 0
        var pad1: Int32 = 0
        var pad2: Int32 = 0
    }

    /// Encodes the effect stack for one pass (a one-plane Gray- or RGB-like image).
    static func encode(_ effects: [GalleryEffect], _ pass: GPUPass) throws {
        let win = pass.srcRect
        if win.isEmpty || effects.isEmpty {
            try pass.dispatchOut("pca_copy", params: NoParams())
            return
        }
        let enc = Encoder(pass)
        var cur = try enc.run("pca_gfx_load", enc.base, [pass.src])
        for e in effects {
            let next = try enc.effect(e, cur)
            if next !== cur { pass.recycle(cur) }
            cur = next
        }
        try pass.dispatchOut("pca_gfx_out", params: enc.base, textures: [pass.src, cur, pass.dst])
    }

    final class Encoder {
        let pass: GPUPass
        let win: PixelRect
        let base: GParams

        init(_ pass: GPUPass) {
            self.pass = pass
            win = pass.srcRect
            let b = pass.ctx.bounds
            var p = GParams(winOrigin: SIMD2(win.x0, win.y0), winSize: SIMD2(Int32(win.width), Int32(win.height)))
            p.bc = SIMD2(Float(b.x0 &+ b.x1) / 2, Float(b.y0 &+ b.y1) / 2)
            p.halfB = Float.maximum(Float(max(b.width, b.height)) / 2, 1)
            base = p
        }

        /// Runs a window kernel reading `inputs` into a new window texture.
        func run(_ kernel: String, _ p: GParams, _ inputs: [any MTLTexture]) throws -> any MTLTexture {
            let o = try pass.texture(win)
            try pass.dispatch(kernel, params: p, textures: inputs + [o], width: win.width, height: win.height)
            return o
        }

        func params(_ e: GalleryEffect, _ v0: SIMD4<Float> = .zero, _ v1: SIMD4<Float> = .zero, _ v2: SIMD4<Float> = .zero,
                    i0: Int32 = 0, i1: Int32 = 0) -> GParams {
            var p = base
            p.fg = e.foreground; p.bg = e.background; p.color = e.color
            p.v0 = v0; p.v1 = v1; p.v2 = v2; p.i0 = i0; p.i1 = i1
            return p
        }

        /// .x plane: luma (mode 0), 1 − luma (1), smoothstep(e0, e1, .x) (2).
        func plane(_ t: any MTLTexture, _ mode: Int32, _ e0: Float = 0, _ e1: Float = 0) throws -> any MTLTexture {
            var p = base
            p.i0 = mode; p.v0 = SIMD4(e0, e1, 0, 0)
            return try run("pca_gfx_plane", p, [t])
        }

        func lum(_ t: any MTLTexture) throws -> any MTLTexture { try plane(t, 0) }

        /// (gx, gy, magnitude) of a plane's .x.
        func sobel(_ t: any MTLTexture) throws -> any MTLTexture { try run("pca_gfx_sobel", base, [t]) }

        /// photocraft `line_blur` / one FxUtil box pass along `d`; `t` itself for r = 0.
        func line(_ t: any MTLTexture, _ d: (Int32, Int32), _ r: Int) throws -> any MTLTexture {
            if r == 0 { return t }
            let (w, h) = (win.width, win.height)
            let lines = d == (1, 0) ? h : d == (0, 1) ? w : w + h - 1
            let len = d == (1, 0) ? w : d == (0, 1) ? h : min(w, h)
            let norm = 1 / Double(2 * r + 1)
            let nh = Float(norm)
            let segment: Int32 = 32
            let p = LineParams(size: SIMD2(Int32(w), Int32(h)), d: SIMD2(d.0, d.1), radius: Int32(r), segment: segment,
                               normHi: nh, normLo: Float(norm - Double(nh)), lines: Int32(lines))
            let o = try pass.texture(win)
            try pass.dispatch("pca_gfx_line_ff", params: p, textures: [t, o], width: lines,
                              height: (len + Int(segment) - 1) / Int(segment), threadgroup: (32, 4))
            return o
        }

        /// FxUtil `gauss_blur_n` (three box passes per axis, rows then columns); `t` for σ < 0.3.
        func gauss(_ t: any MTLTexture, _ sigma: Float) throws -> any MTLTexture {
            if sigma < 0.3 { return t }
            let radii = FxUtil.gaussBoxRadii(sigma)
            var cur = t
            for d: (Int32, Int32) in [(1, 0), (0, 1)] {
                for r in radii where r > 0 {
                    let o = try line(cur, d, r)
                    if cur !== t { pass.recycle(cur) }
                    cur = o
                }
            }
            return cur
        }

        /// FxUtil `box_blur_n`: rows then columns of radius r.
        func box(_ t: any MTLTexture, _ r: Int) throws -> any MTLTexture {
            let a = try line(t, (1, 0), r)
            let b = try line(a, (0, 1), r)
            if a !== t && a !== b { pass.recycle(a) }
            return b
        }

        func kuwahara(_ c: any MTLTexture, _ r: Int) throws -> any MTLTexture {
            let h2 = max((r + 1) / 2, 1)
            let m1 = try pass.texture(win), m2 = try pass.texture(win)
            try pass.dispatch("pca_gfx_kuwa_prep", params: base, textures: [c, m1, m2], width: win.width, height: win.height)
            let b1 = try box(m1, h2), b2 = try box(m2, h2)
            pass.recycle(m1); pass.recycle(m2)
            var p = base
            p.i0 = Int32(h2)
            let o = try run("pca_gfx_kuwa_select", p, [b1, b2])
            pass.recycle(b1); pass.recycle(b2)
            return o
        }

        func unsharp(_ c: any MTLTexture, _ sigma: Float, _ amount: Float) throws -> any MTLTexture {
            if amount <= 0 { return c }
            let b = try gauss(c, sigma)
            var p = base
            p.v0 = SIMD4(amount, 0, 0, 0)
            let o = try run("pca_gfx_unsharp", p, [c, b])
            if b !== c { pass.recycle(b) }
            return o
        }

        func texturize(_ c: any MTLTexture, _ kind: String, _ scaling: Float, _ relief: Float, _ light: String, _ invert: Bool,
                       weighted: Bool = false) throws -> any MTLTexture {
            if relief <= 0 { return c }
            let l = GalleryFXKit.lightDir(light)
            var p = base
            p.v0 = SIMD4(clampf(scaling / 100, 0.5, 2), relief / 50 * 3, invert ? -1 : 1, 0)
            p.v1 = SIMD4(l.0, l.1, 0, 0)
            p.i0 = GalleryFXKit.textureCode(kind); p.i1 = weighted ? 1 : 0
            return try run("pca_gfx_texturize", p, [c])
        }

        /// Recycles every texture in `ts` that is not `keep` (intermediates of an effect).
        func drop(_ ts: [any MTLTexture], keeping keep: [any MTLTexture]) {
            for t in ts where !keep.contains(where: { $0 === t }) && t !== pass.src && t !== pass.dst { pass.recycle(t) }
        }

        // swiftlint:disable:next cyclomatic_complexity function_body_length
        func effect(_ e: GalleryEffect, _ cur: any MTLTexture) throws -> any MTLTexture {
            let g = { (k: String) in e.get(k) }
            let fx = "pca_gfx_fx_" + e.filter.rawValue
            var tmp: [any MTLTexture] = []
            @discardableResult func keep(_ t: any MTLTexture) -> any MTLTexture { tmp.append(t); return t }
            defer { drop(tmp, keeping: [cur]) }
            switch e.filter {
            case .coloredPencil:
                let pw = g("pencilWidth")
                let pb = g("paperBrightness")
                let paper = GalleryFXKit.map(GalleryFXKit.rgb(e.background)) { $0 * (0.7 + 0.3 * pb / 50) }
                let s = keep(try sobel(keep(try lum(cur))))
                return try run(fx, params(e, SIMD4(5 + pw * 3, 0.5 + pw * 0.45, g("strokePressure") / 15, 0), SIMD4(paper, 0)), [cur, s])
            case .cutout:
                let b = keep(try gauss(cur, GalleryFXKit.cutoutSigma(e)))
                return try run(fx, params(e, SIMD4(g("numberOfLevels").rounded(.toNearestOrAwayFromZero), 0, 0, 0)), [b])
            case .dryBrush, .fresco:
                let fresco = e.filter == .fresco
                let k = keep(try kuwahara(cur, 1 + PCAMath.usize(g("brushSize"))))
                let u = keep(try unsharp(k, 1, fresco ? 0.9 : 0.5))
                let s = fresco ? keep(try sobel(keep(try lum(u)))) : u
                return try run("pca_gfx_fx_dryBrush", params(e, SIMD4(3 + g("brushDetail"), 0.02 + (g("texture") - 1) * 0.05, fresco ? 1 : 0, 0)), [u, s])
            case .filmGrain:
                return try run(fx, params(e, SIMD4(g("grain") / 20, g("highlightArea"), g("intensity"), 0)), [cur])
            case .neonGlow:
                let size = g("glowSize")
                let m = keep(try plane(cur, size >= 0 ? 0 : 1))
                let mb = keep(try gauss(m, abs(size) * 0.6 + 0.5))
                return try run(fx, params(e, SIMD4(g("glowBrightness") / 50, 0, 0, 0)), [cur, mb])
            case .paintDaubs:
                let ty = e.choice("brushType")
                let k = keep(try kuwahara(cur, GalleryFXKit.daubsRadius(e)))
                let sharp = g("sharpness") / 40
                let b: any MTLTexture
                switch ty {
                case "wideBlurry": b = keep(try gauss(k, 1.5))
                case "wideSharp": b = keep(try unsharp(k, 1.5, sharp * 4))
                default: b = keep(try unsharp(k, 1.2, sharp * 2.5))
                }
                let mode: Int32 = switch ty { case "lightRough": 1; case "darkRough": 2; case "sparkle": 3; default: 0 }
                if mode == 0 { tmp.removeAll { $0 === b }; return b }
                let s = mode == 3 ? keep(try sobel(keep(try lum(b)))) : b
                return try run(fx, params(e, i0: mode), [b, s])
            case .paletteKnife:
                let k = keep(try kuwahara(cur, PCAMath.usize(GalleryFXKit.fmax(g("strokeSize") / 3, 1))))
                let q = keep(try run(fx, params(e, SIMD4(2 + g("strokeDetail") * 3, 0, 0, 0)), [k]))
                let o = try gauss(q, g("softness") * 0.5)
                if o === q { tmp.removeAll { $0 === q } }
                return o
            case .plasticWrap:
                let lb = keep(try gauss(keep(try lum(cur)), GalleryFXKit.plasticSigma(e)))
                let s = keep(try sobel(lb))
                let hv = GalleryFXKit.plasticVectors.1
                return try run(fx, params(e, SIMD4(g("highlightStrength") / 20, 0, 0, 0), SIMD4(hv, 0)), [cur, s])
            case .posterEdges:
                let lb = keep(try gauss(keep(try lum(cur)), 0.6 + g("edgeThickness") * 0.6))
                let s = keep(try sobel(lb))
                return try run(fx, params(e, SIMD4(g("edgeIntensity") / 10, g("posterization") + 2, 0, 0)), [cur, s])
            case .roughPastels:
                let len = g("strokeLength")
                let det = (g("strokeDetail") - 1) / 19
                var c = cur
                if len >= 1 {
                    let soft = keep(try gauss(cur, 0.6 + (1 - det) * 1.2))
                    c = keep(try run(fx, params(e, SIMD4(len, det, 0, 0)), [cur, soft]))
                }
                let o = try texturize(c, e.choice("texture"), g("scaling"), g("relief"), e.choice("light"), e.flag("invert"), weighted: true)
                if o === c { tmp.removeAll { $0 === c } }
                return o
            case .smudgeStick:
                let lb = keep(try line(cur, (1, 1), PCAMath.usize(g("strokeLength") * 1.5)))
                return try run(fx, params(e, SIMD4(g("highlightArea"), g("intensity"), 0, 0)), [lb])
            case .sponge:
                let k = keep(try kuwahara(cur, 1 + PCAMath.usize(g("brushSize"))))
                return try run(fx, params(e, SIMD4(g("definition") / 25, 1.5 + g("smoothness") * 0.5, 0, 0)), [k])
            case .underpainting:
                let b = keep(try gauss(cur, 0.5 + g("brushSize") * 0.4))
                let m = keep(try run(fx, params(e), [cur, b]))
                let cov = g("textureCoverage") / 40
                let o = try texturize(m, e.choice("texture"), g("scaling"), g("relief") * (0.5 + cov * 1.5), e.choice("light"), e.flag("invert"))
                if o === m { tmp.removeAll { $0 === m } }
                return o
            case .watercolor:
                let k = keep(try kuwahara(cur, GalleryFXKit.watercolorRadius(e)))
                let s = keep(try sobel(keep(try lum(k))))
                return try run(fx, params(e, SIMD4(g("shadowIntensity") / 10, (g("texture") - 1) * 0.04, 0, 0)), [k, s])
            case .accentedEdges:
                let lb = keep(try gauss(keep(try lum(cur)), 0.4 + g("smoothness") * 0.3))
                let eb = keep(try gauss(keep(try sobel(lb)), g("edgeWidth") * 0.5))
                return try run(fx, params(e, SIMD4(g("edgeBrightness") / 50, 0, 0, 0)), [cur, eb])
            case .angledStrokes:
                let soft = keep(try gauss(cur, 0.8))
                let a = keep(try run(fx, params(e, SIMD4(GalleryFXKit.fmax(g("strokeLength"), 3), g("directionBalance") / 100, 0, 0)), [soft]))
                let o = try unsharp(a, 1, 0.2 + g("sharpness") / 10 * 2.3)
                if o === a { tmp.removeAll { $0 === a } }
                return o
            case .crosshatch:
                let r = PCAMath.usize(g("strokeLength") / 3)
                let n = keep(try run(fx, params(e, SIMD4(g("strength"), 0, 0, 0)), [cur]))
                let a = keep(try line(n, (1, 1), r)), b = keep(try line(n, (1, -1), r))
                var p = base
                p.v0 = SIMD4(0.5, 0, 0, 0)
                let m = keep(try run("pca_gfx_blend", p, [a, b]))
                let o = try unsharp(m, 1, g("sharpness") / 20 * 3)
                if o === m { tmp.removeAll { $0 === m } }
                return o
            case .darkStrokes:
                let a = keep(try line(cur, (1, 1), 3)), b = keep(try line(cur, (1, -1), 8))
                return try run(fx, params(e, SIMD4(g("blackIntensity") / 10, g("whiteIntensity") / 10, 0.25 + g("balance") / 10 * 0.5, 0)), [cur, a, b])
            case .inkOutlines:
                let s = keep(try sobel(keep(try lum(cur))))
                let lb = keep(try line(cur, (1, 1), PCAMath.usize(g("strokeLength") / 2)))
                return try run(fx, params(e, SIMD4(g("darkIntensity") / 50, g("lightIntensity") / 50, 0, 0)), [cur, s, lb])
            case .spatter, .sprayedStrokes:
                let sc: Float = e.filter == .spatter ? 0.6 + g("smoothness") * 0.25 : 1.2
                let o = try run("pca_gfx_fx_spatter", params(e, SIMD4(g("sprayRadius"), sc, 0, 0)), [cur])
                if e.filter == .spatter { return o }
                keep(o)
                let l = try line(o, GalleryFXKit.direction(e.choice("strokeDirection")), PCAMath.usize(g("strokeLength") / 2))
                if l === o { tmp.removeAll { $0 === o } }
                return l
            case .sumiE:
                let sw = g("strokeWidth")
                let b = keep(try gauss(cur, sw * 0.2))
                let lb = keep(try line(b, (1, 1), PCAMath.usize(sw / 2)))
                return try run(fx, params(e, SIMD4(g("strokePressure") / 15, g("contrast") / 40, 0, 0)), [lb])
            case .diffuseGlow:
                return try run(fx, params(e, SIMD4(g("graininess") / 10, g("glowAmount") / 20, 0.2 + g("clearAmount") / 20 * 0.7, 0)), [cur])
            case .glass:
                let dist = g("distortion")
                return try run(fx, params(e, SIMD4(dist, 0.5 + g("smoothness") * 0.5, clampf(g("scaling") / 100, 0.5, 2), e.flag("invert") ? -1 : 1),
                                          SIMD4(dist * 2, 0, 0, 0), i0: GalleryFXKit.textureCode(e.choice("texture"))), [cur])
            case .oceanRipple:
                return try run(fx, params(e, SIMD4(2 + g("rippleSize") * 1.2, g("rippleMagnitude") * 0.9, 0, 0)), [cur])
            case .basRelief:
                let lb = keep(try gauss(keep(try lum(cur)), GalleryFXKit.basreliefSigma(e)))
                let s = keep(try sobel(lb))
                let lt = GalleryFXKit.lightDir(e.choice("light"))
                return try run(fx, params(e, SIMD4(lt.0, lt.1, 3 + g("detail") * 0.4, 0)), [cur, s])
            case .chalkCharcoal:
                return try run(fx, params(e, SIMD4(g("charcoalArea") / 20, g("chalkArea") / 20, g("strokePressure") / 5, 0)), [cur])
            case .charcoal:
                let lb = keep(try gauss(keep(try lum(cur)), 1))
                let s = keep(try sobel(lb))
                return try run(fx, params(e, SIMD4(g("charcoalThickness"), g("detail") / 5, g("lightDarkBalance") / 100, 0)), [lb, s])
            case .chrome:
                let lb = keep(try gauss(keep(try lum(cur)), 1 + g("smoothness") / 10 * 4))
                let s = keep(try sobel(lb))
                return try run(fx, params(e, SIMD4(g("detail") / 10, 0, 0, 0)), [lb, s])
            case .conteCrayon:
                let c = keep(try run(fx, params(e, SIMD4(g("foregroundLevel") / 15, g("backgroundLevel") / 15, 0, 0)), [cur]))
                let o = try texturize(c, e.choice("texture"), g("scaling"), g("relief"), e.choice("light"), e.flag("invert"))
                if o === c { tmp.removeAll { $0 === c } }
                return o
            case .graphicPen:
                let r = PCAMath.usize(g("strokeLength") / 2)
                let n = try pass.texture(win)
                keep(n)
                try pass.dispatch("pca_gfx_hash_plane", params: base, textures: [n], width: win.width, height: win.height)
                let nb = keep(try line(n, GalleryFXKit.direction(e.choice("strokeDirection")), r))
                let sd = 0.2887 / Float(2 * r + 1).squareRoot()
                return try run(fx, params(e, SIMD4(g("lightDarkBalance") / 100, sd, 0, 0)), [cur, nb])
            case .halftonePattern:
                let size = g("size")
                let lb = keep(try gauss(keep(try lum(cur)), 0.5 + size * 0.3))
                let ty: Int32 = switch e.choice("patternType") { case "circle": 1; case "line": 2; default: 0 }
                return try run(fx, params(e, SIMD4(3 + size * 2, g("contrast") / 50, 0, 0), i0: ty), [lb])
            case .notePaper:
                let bal = g("imageBalance") / 50
                let lb = keep(try gauss(keep(try lum(cur)), 1))
                let mb = keep(try gauss(keep(try plane(lb, 2, bal - 0.05, bal + 0.05)), 1.2))
                let s = keep(try sobel(mb))
                let tl = GalleryFXKit.lightDir("topLeft")
                return try run(fx, params(e, SIMD4(g("graininess") / 20, g("relief") / 25, 0, 0), SIMD4(tl.0, tl.1, 0, 0)), [mb, s])
            case .photocopy:
                let b = keep(try gauss(keep(try lum(cur)), 1 + g("detail") * 0.5))
                return try run(fx, params(e, SIMD4(g("darkness") / 50, 0, 0, 0)), [cur, b])
            case .plaster:
                let bal = g("imageBalance") / 50
                let lb = keep(try gauss(keep(try lum(cur)), 0.5 + g("smoothness") * 0.8))
                let mb = keep(try gauss(keep(try plane(lb, 2, bal + 0.1, bal - 0.1)), 1.5))
                let s = keep(try sobel(mb))
                let lt = GalleryFXKit.lightDir(e.choice("light"))
                return try run(fx, params(e, .zero, SIMD4(lt.0, lt.1, 0, 0)), [mb, s])
            case .reticulation:
                let (fg, bg) = (GalleryFXKit.rgb(e.foreground), GalleryFXKit.rgb(e.background))
                let inkC = GalleryFXKit.mix(bg, fg, 0.3 + g("foregroundLevel") / 50 * 0.7)
                let paper = GalleryFXKit.mix(bg, fg, g("backgroundLevel") / 50 * 0.6)
                return try run(fx, params(e, SIMD4(g("density") / 50, 0, 0, 0), SIMD4(inkC, 0), SIMD4(paper, 0)), [cur])
            case .stamp:
                let lb = keep(try gauss(keep(try lum(cur)), 0.3 + g("smoothness") * 0.3))
                return try run(fx, params(e, SIMD4(g("lightDarkBalance") / 50, 0, 0, 0)), [lb])
            case .tornEdges:
                let lb = keep(try gauss(keep(try lum(cur)), 1))
                let (sm, con) = (g("smoothness"), g("contrast"))
                return try run(fx, params(e, SIMD4(g("imageBalance") / 50, (16 - sm) / 15 * 0.35, 0.25 / con, 0)), [lb])
            case .waterPaper:
                let fl = g("fiberLength")
                let r = PCAMath.usize(fl / 6)
                let a = keep(try line(cur, (1, 0), r))
                let b = keep(try line(a, (0, 1), r))
                return try run(fx, params(e, SIMD4(fl, g("brightness") / 100, g("contrast") / 100, 0)), [b])
            case .glowingEdges:
                // The standalone GlowingEdges' passes: core Gaussian, its Sobel kernel, core Gaussian.
                let smooth = keep(try pass.encodeGaussBlurN(cur, rect: win, sigma: 0.3 + g("smoothness") * 0.25))
                let gp = GlowParams(winOrigin: SIMD2(win.x0, win.y0), winSize: SIMD2(Int32(win.width), Int32(win.height)), gain: 0)
                let edges = keep(try pass.texture(win))
                try pass.dispatch("pca_sty_glow_sobel", params: gp, textures: [smooth, edges], width: win.width, height: win.height)
                let glow = keep(try pass.encodeGaussBlurN(edges, rect: win, sigma: g("edgeWidth") * 0.4))
                return try run(fx, params(e, SIMD4(2 + g("edgeBrightness") * 1.2, 0, 0, 0)), [glow])
            case .craquelure:
                let dep = g("crackDepth") / 10
                let tl = GalleryFXKit.lightDir("topLeft")
                return try run(fx, params(e, SIMD4(g("crackSpacing") * 1.3 + 1, 0.8 + dep * 0.8, dep, g("crackBrightness") / 10), SIMD4(tl.0, tl.1, 0, 0)), [cur])
            case .grain:
                let types = ["regular", "soft", "sprinkles", "clumped", "contrasty", "enlarged", "stippled", "horizontal", "vertical", "speckle"]
                let ty = Int32(types.firstIndex(of: e.choice("grainType")) ?? 0)
                return try run(fx, params(e, SIMD4(g("intensity") / 100, g("contrast") / 100, 0, 0), i0: ty), [cur])
            case .mosaicTiles:
                return try run(fx, params(e, SIMD4(g("tileSize"), g("groutWidth"), g("lightenGrout") / 10, 0)), [cur])
            case .patchwork:
                return try run(fx, params(e, SIMD4(GalleryFXKit.patchSize(e), g("relief") / 25, 0, 0)), [cur])
            case .stainedGlass:
                return try run(fx, params(e, SIMD4(GalleryFXKit.glassCell(e), g("borderThickness"), g("lightIntensity") / 10, 0)), [cur])
            case .texturizer:
                return try texturize(cur, e.choice("texture"), g("scaling"), g("relief"), e.choice("light"), e.flag("invert"))
            }
        }
    }
}
