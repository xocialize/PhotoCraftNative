// Port of photocraft-algo (crates/algo/src/camera_raw/local_tone.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Camera Raw's Shadows and Highlights as a local Laplacian filter (S. Paris, S. W. Hasinoff,
// J. Kautz, "Local Laplacian Filters", SIGGRAPH 2011) in its fast form (M. Aubry et al., "Fast
// Local Laplacian Filters", ACM TOG 2014: the remapping sampled at reference values an eighth of a
// stop apart, each pyramid coefficient interpolated between them), on the log2 luminance.
// Shadows raises pixels darker than their surroundings, Highlights pulls brighter ones toward
// them; differences under a threshold are left alone. Strengths fitted by photocraft to
// Photoshop 25.4's Camera Raw Filter (black-box). CPU only: a pyramid per reference value.

import Foundation
import PCFoundation

extension CameraRawKit {
    enum LocalTone {
        /// Spacing of the reference values in stops.
        static let refStep: Float = 0.125
        /// The filter runs on a copy at most this many pixels across.
        static let workSide = 1600

        struct Lift { var own: [Float]; var around: [Float]; var sigma: Float; var down: Float }
        struct Side { var pull: [Float]; var push: [Float]; var sigma: Float }

        static let shadows = Lift(own: [-0.017, 0.466, 0.886, 1.221, -0.081], around: [4.566, 4.067, 1.088, 0.149, 0.878], sigma: 0.571, down: 0.808)
        static let highlights = Side(pull: [0.179, 0.141, 0.196, 0.629, 2.07], push: [0.156, 0.08, 0.175, 0.049, 1.261], sigma: 0.05)

        /// One channel, `w × h`.
        struct Plane { var w: Int; var h: Int; var v: [Float] }

        /// Mirrors `i` into 0..<n (the edge sample is not repeated).
        @inline(__always)
        static func mirror(_ i: Int, _ n: Int) -> Int {
            if n == 1 { return 0 }
            let p = 2 * (n - 1)
            var m = i % p
            if m < 0 { m += p }
            return m >= n ? p - m : m
        }

        /// The binomial 5-tap blur, sampled every `step` pixels from 0 (columns first at the kept
        /// rows, then rows at the kept columns). Taps 1/16, 4/16, 6/16, 4/16, 1/16 summed in order.
        static func blurStep(_ p: Plane, _ step: Int) -> Plane {
            let (t0, t1, t2): (Float, Float, Float) = (1.0 / 16, 4.0 / 16, 6.0 / 16)
            let pw = p.w, ph = p.h
            let w2 = (pw + step - 1) / step, h2 = (ph + step - 1) / step
            var tmp = [Float](repeating: 0, count: pw * h2)
            p.v.withUnsafeBufferPointer { src in
                tmp.withUnsafeMutableBufferPointer { t in
                    let (ss, ts) = (UnsafeSendable(src.baseAddress!), UnsafeSendable(t.baseAddress!))
                    parallelChunks(h2, minChunk: 4) { rows in
                        let s = ss.value, o = ts.value
                        for y2 in rows {
                            let y = y2 * step
                            let r0 = s + mirror(y - 2, ph) * pw, r1 = s + mirror(y - 1, ph) * pw, r2 = s + mirror(y, ph) * pw
                            let r3 = s + mirror(y + 1, ph) * pw, r4 = s + mirror(y + 2, ph) * pw
                            let d = o + y2 * pw
                            for x in 0..<pw {
                                var a: Float = -0.0
                                a += t0 * r0[x]; a += t1 * r1[x]; a += t2 * r2[x]; a += t1 * r3[x]; a += t0 * r4[x]
                                d[x] = a
                            }
                        }
                    }
                }
            }
            var out = [Float](repeating: 0, count: w2 * h2)
            tmp.withUnsafeBufferPointer { t in
                out.withUnsafeMutableBufferPointer { o in
                    let (ts, os) = (UnsafeSendable(t.baseAddress!), UnsafeSendable(o.baseAddress!))
                    parallelChunks(h2, minChunk: 4) { rows in
                        for y2 in rows {
                            let row = ts.value + y2 * pw, d = os.value + y2 * w2
                            for x2 in 0..<w2 {
                                let x = x2 * step
                                let (i0, i1, i2, i3, i4): (Int, Int, Int, Int, Int)
                                if x >= 2 && x + 2 < pw { (i0, i1, i2, i3, i4) = (x - 2, x - 1, x, x + 1, x + 2) }
                                else { (i0, i1, i2, i3, i4) = (mirror(x - 2, pw), mirror(x - 1, pw), mirror(x, pw), mirror(x + 1, pw), mirror(x + 2, pw)) }
                                var a: Float = -0.0
                                a += t0 * row[i0]; a += t1 * row[i1]; a += t2 * row[i2]; a += t1 * row[i3]; a += t0 * row[i4]
                                d[x2] = a
                            }
                        }
                    }
                }
            }
            return Plane(w: w2, h: h2, v: out)
        }

        /// The next coarser level.
        static func down(_ p: Plane) -> Plane { blurStep(p, 2) }

        /// `p` brought up to `w × h`: zeros between samples, then the blur times four.
        static func up(_ p: Plane, _ w: Int, _ h: Int) -> Plane {
            var z = Plane(w: w, h: h, v: [Float](repeating: 0, count: w * h))
            let (ny, nx) = (min(p.h, (h + 1) / 2), min(p.w, (w + 1) / 2))
            p.v.withUnsafeBufferPointer { s in
                z.v.withUnsafeMutableBufferPointer { d in
                    for y in 0..<ny { for x in 0..<nx { d[2 * y * w + 2 * x] = s[y * p.w + x] * 4 } }
                }
            }
            return blurStep(z, 1)
        }

        /// Levels down to about 2 pixels on the short side.
        static func depth(_ w: Int, _ h: Int) -> Int {
            var s = min(w, h), n = 1
            while s > 2 { s = (s + 1) / 2; n += 1 }
            return n
        }

        static func gaussian(_ p: Plane, _ n: Int) -> [Plane] {
            var g = [p]
            for _ in 1..<max(n, 1) { g.append(down(g[g.count - 1])) }
            return g
        }

        /// The local Laplacian filter of `u` with `remap(value, reference)`; the coarsest level kept.
        static func llf(_ u: Plane, _ remap: (Float, Float) -> Float) -> Plane {
            let n = depth(u.w, u.h)
            let g = gaussian(u, n)
            // References span the image's tones; the deepest 0.1 % share the lowest one.
            var hi = -Float.infinity
            for v in u.v { hi = Float.maximum(hi, v) }
            let lo = Float.minimum(quantile(u.v, 0.001), hi)
            if hi - lo <= 1e-6 || (hi - lo).isNaN { return u }
            let refs = min(max(Int(((hi - lo) / refStep).rounded(.up)) + 1, 2), 96)
            let step = (hi - lo) / Float(refs - 1)
            var lap: [[Float]] = g[0..<(n - 1)].map { [Float](repeating: 0, count: $0.v.count) }
            for k in 0..<refs {
                let r = lo + step * Float(k)
                var m = u
                m.v.withUnsafeMutableBufferPointer { b in
                    let bs = UnsafeSendable(b)
                    withoutActuallyEscaping(remap) { re in
                        nonisolated(unsafe) let rf = re
                        parallelChunks(b.count, minChunk: 8192) { rr in for i in rr { bs.value[i] = rf(bs.value[i], r) } }
                    }
                }
                let gr = gaussian(m, n)
                for l in 0..<(n - 1) {
                    let coarse = up(gr[l + 1], gr[l].w, gr[l].h)
                    g[l].v.withUnsafeBufferPointer { glb in
                        gr[l].v.withUnsafeBufferPointer { fb in
                            coarse.v.withUnsafeBufferPointer { cb in
                                lap[l].withUnsafeMutableBufferPointer { lb in
                                    let (gs, fs, cs, ls) = (UnsafeSendable(glb.baseAddress!), UnsafeSendable(fb.baseAddress!),
                                                            UnsafeSendable(cb.baseAddress!), UnsafeSendable(lb.baseAddress!))
                                    parallelChunks(lb.count, minChunk: 8192) { rr in
                                        let (gl, fine, co, la) = (gs.value, fs.value, cs.value, ls.value)
                                        for i in rr {
                                            let wgt = Float.maximum(1 - abs(clampf(gl[i], lo, hi) - r) / step, 0)
                                            if wgt > 0 { la[i] += wgt * (fine[i] - co[i]) }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            var o = g[n - 1]
            for l in stride(from: n - 2, through: 0, by: -1) {
                var next = up(o, g[l].w, g[l].h)
                lap[l].withUnsafeBufferPointer { lb in
                    next.v.withUnsafeMutableBufferPointer { nb in for i in 0..<nb.count { nb[i] += lb[i] } }
                }
                o = next
            }
            return o
        }

        /// The `q` quantile (0…1) of `v`.
        static func quantile(_ v: [Float], _ q: Float) -> Float {
            let s = ToneKit.totalSorted(v)
            return s[Int((Float(s.count - 1) * q).rounded())]
        }

        /// 1st and 99th percentiles of the log luminance on a copy at most 256 px across.
        static func range(_ u: Plane) -> (Float, Float) {
            let f = max((max(u.w, u.h) + 255) / 256, 1)
            let sw = (u.w + f - 1) / f, sh = (u.h + f - 1) / f
            var sum = [Double](repeating: 0, count: sw * sh), cnt = [UInt32](repeating: 0, count: sw * sh)
            for y in 0..<u.h {
                for x in 0..<u.w { let k = (y / f) * sw + x / f; sum[k] += Double(u.v[y * u.w + x]); cnt[k] += 1 }
            }
            let cells: [Float] = (0..<(sw * sh)).filter { cnt[$0] > 0 }.map { Float(sum[$0] / Double(cnt[$0])) }
            return (quantile(cells, 0.01), quantile(cells, 0.99))
        }

        /// `d` past the detail threshold: about 0 below `sigma`, `d − sigma` well above it.
        @inline(__always)
        static func excess(_ d: Float, _ sigma: Float) -> Float { d - sigma * tanhf(d / sigma) }

        @inline(__always)
        static func knot(_ t: Float, _ k: [Float]) -> Float {
            let x = clampf(t, 0, 1) * Float(k.count - 1)
            let i = min(Int(x), k.count - 2)
            return k[i] + (k[i + 1] - k[i]) * (x - Float(i))
        }

        /// The Highlights pass on the log luminance `u` (`amount` −1…1).
        static func highlightsPass(_ u: Plane, _ amount: Float, _ side: Side) -> Plane {
            let (lo, hi) = range(u)
            let span = Float.maximum(hi - lo, 1)
            let strengths = amount < 0 ? side.pull : side.push
            let o = llf(u) { x, g in x + knot((g - lo) / span, strengths) * amount * excess(Float.maximum(x - g, 0), side.sigma) }
            let shift = quantile(u.v, 0.01) - quantile(o.v, 0.01)
            return Plane(w: o.w, h: o.h, v: o.v.map { $0 + shift })
        }

        /// The Shadows pass on the log luminance `u` (`amount` −1…1).
        static func shadowsPass(_ u: Plane, _ amount: Float) -> Plane {
            let (lo, hi) = range(u)
            let span = Float.maximum(hi - lo, 1)
            let k = amount > 0 ? amount : amount * shadows.down
            let o = llf(u) { x, g in
                let below = clampf((g - x) / shadows.sigma, 0, 1)
                if below == 0 { return x }
                let w = below * below * (3 - 2 * below)
                return x + k * knot((x - lo) / span, shadows.own) * knot((g - lo) / span, shadows.around) * w
            }
            // Keep the brightest content.
            let shift = quantile(u.v, 0.99) - quantile(o.v, 0.99)
            return Plane(w: o.w, h: o.h, v: o.v.map { $0 + shift })
        }

        /// Applies Shadows and Highlights (−100…100) to straight RGBA pixels encoded with `enc`.
        static func apply(_ px: inout [SIMD4<Float>], _ w: Int, _ h: Int, _ shadowsAmount: Float, _ highlightsAmount: Float, _ enc: Encoding) {
            if (shadowsAmount == 0 && highlightsAmount == 0) || w < 2 || h < 2 { return }
            let floor: Float = 1.0 / 65536
            let u = Plane(w: w, h: h, v: px.map { q in
                log2f(Float.maximum(luma(SIMD3(enc.decode(q.x), enc.decode(q.y), enc.decode(q.z))), 0) + floor)
            })
            // The filter on a copy at most `workSide` across (box-averaged in log).
            let f = max((max(w, h) + workSide - 1) / workSide, 1)
            let small = f == 1 ? u : shrink(u, f)
            var o = small
            if highlightsAmount != 0 { o = highlightsPass(o, clampf(highlightsAmount, -100, 100) / 100, highlights) }
            if shadowsAmount != 0 { o = shadowsPass(o, clampf(shadowsAmount, -100, 100) / 100) }
            // The change in log luminance, at full size.
            let change: [Float]
            if f == 1 { change = zip(o.v, u.v).map { $0 - $1 } }
            else { change = guidedUpsample(small, zip(o.v, small.v).map { $0 - $1 }, u) }
            px.withUnsafeMutableBufferPointer { q in
                let qs = UnsafeSendable(q)
                parallelChunks(q.count, minChunk: 4096) { r in
                    for i in r {
                        let gain = exp2f(change[i])
                        for c in 0..<3 { qs.value[i][c] = enc.encode(enc.decode(qs.value[i][c]) * gain) }
                    }
                }
            }
        }

        /// `u` averaged over `f × f` blocks.
        static func shrink(_ u: Plane, _ f: Int) -> Plane {
            let sw = (u.w + f - 1) / f, sh = (u.h + f - 1) / f
            var v = [Float](repeating: 0, count: sw * sh)
            for y in 0..<sh {
                for x in 0..<sw {
                    let (x0, y0) = (x * f, y * f)
                    let (x1, y1) = (min(x0 + f, u.w), min(y0 + f, u.h))
                    var s = 0.0
                    for yy in y0..<y1 { for xx in x0..<x1 { s += Double(u.v[yy * u.w + xx]) } }
                    v[y * sw + x] = Float(s / Double((x1 - x0) * (y1 - y0)))
                }
            }
            return Plane(w: sw, h: sh, v: v)
        }

        /// The change `d` computed on `small` brought to the size of `full` by a guided
        /// upsampling against the log luminance (He & Sun, "Fast Guided Filter", 2015).
        static func guidedUpsample(_ small: Plane, _ d: [Float], _ full: Plane) -> [Float] {
            let (sw, sh) = (small.w, small.h)
            let r = 2
            let eps: Float = 0.01
            func mean(_ v: [Float]) -> [Float] { boxMean(v, sw, sh, r) }
            let ud = zip(small.v, d).map { $0 * $1 }, uu = small.v.map { $0 * $0 }
            let (mu, md, mud, muu) = (mean(small.v), mean(d), mean(ud), mean(uu))
            let a = (0..<(sw * sh)).map { i in (mud[i] - mu[i] * md[i]) / (muu[i] - mu[i] * mu[i] + eps) }
            let b = (0..<(sw * sh)).map { i in md[i] - a[i] * mu[i] }
            let ma = mean(a), mb = mean(b)
            let fx = Float(sw) / Float(full.w), fy = Float(sh) / Float(full.h)
            var out = [Float](repeating: 0, count: full.w * full.h)
            ma.withUnsafeBufferPointer { mab in
                mb.withUnsafeBufferPointer { mbb in
                    for y in 0..<full.h {
                        let sy = (Float(y) + 0.5) * fy - 0.5
                        for x in 0..<full.w {
                            let sx = (Float(x) + 0.5) * fx - 0.5
                            out[y * full.w + x] = bilinear(mab, sw, sh, sx, sy) * full.v[y * full.w + x] + bilinear(mbb, sw, sh, sx, sy)
                        }
                    }
                }
            }
            return out
        }
    }
}
