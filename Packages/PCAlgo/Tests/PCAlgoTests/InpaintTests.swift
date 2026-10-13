// Port of photocraft-algo (crates/algo/src/inpaint.rs tests, inpaint/proximity_integral/tests.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import Testing
@testable import PCAlgo
import PCFoundation

enum InpaintFixtures {
    typealias Px = InpaintKit.Px

    /// Smooth gradient plus deterministic fine noise.
    static func texture(_ w: Int, _ h: Int) -> [Float] {
        var rng = InpaintKit.Rng(7)
        var out: [Float] = []
        for i in 0..<(w * h) {
            let (x, y) = (Float(i % w), Float(i / w))
            let n = Float(rng.next() % 1000) / 1000 * 0.04 - 0.02
            out += [0.3 + 0.004 * x + n, 0.5 + 0.002 * y + n, 0.4 + n]
        }
        return out
    }

    static func disc(_ w: Int, _ h: Int, _ cx: Float, _ cy: Float, _ r: Float) -> [Bool] {
        (0..<(w * h)).map { i in hypotf(Float(i % w) - cx, Float(i / w) - cy) < r }
    }

    static func holeRMSE(_ a: [Float], _ b: [Float], _ hole: [Bool], _ ch: Int) -> Float {
        var e: Float = 0
        var n = 0
        for (i, hh) in hole.enumerated() where hh {
            for c in 0..<ch { let d = a[i * ch + c] - b[i * ch + c]; e += d * d; n += 1 }
        }
        return (e / Float(n)).squareRoot()
    }

    /// Structure, fine noise and flat patches (so that some matches tie exactly), `ch` channels.
    static func busy(_ w: Int, _ h: Int, _ ch: Int, _ seed: UInt64) -> [Float] {
        var rng = InpaintKit.Rng(seed)
        var out: [Float] = []
        for i in 0..<(w * h) {
            let (x, y) = (i % w, i / w)
            let flat = (x / 9 + y / 7) % 5 == 0
            let n = Float(rng.next() % 1000) / 1000
            for c in 0..<ch {
                out.append(flat ? 0.25 + 0.1 * Float(c) : Float.minimum(0.2 + 0.004 * Float(x) + 0.1 * Float((x + 2 * y + c) % 6) + 0.05 * n, 1))
            }
        }
        return out
    }

    static func bits(_ v: [Float]) -> [UInt32] { v.map(\.bitPattern) }

    /// Roles: a hole, a band that is context only, a corner that is no image.
    static func roles(_ w: Int, _ h: Int, _ hole: [Bool]) -> [Px] {
        (0..<(w * h)).map { i in
            let (x, y) = (i % w, i / w)
            if hole[i] { return .hole }
            if x < 4 && y < 6 { return .void }
            if (w * 3 / 4..<(w * 3 / 4 + 3)).contains(x) { return .known }
            return .source
        }
    }
}

@Suite struct InpaintTests {
    typealias F = InpaintFixtures
    typealias K = InpaintKit

    /// The Metal stages (costs, transforms, vote, source moments) give the CPU reference's result to
    /// the bit: whole completions compared on every channel count, with and without colour
    /// adaptation, with void and context-only pixels.
    @Test func completionParityIsExact() throws {
        guard AlgoGPU.isAvailable else { return }
        // Every kernel compiles (a silent CPU fallback would make the comparison vacuous).
        for name in ["pca_inp_proximity", "pca_inp_source_moments", "pca_inp_costs", "pca_inp_transforms", "pca_inp_vote"] {
            _ = try AlgoGPU.shared().pipeline(name)
        }
        let cases: [(Int, Int, Int, K.Adapt, Bool)] = [
            (90, 72, 3, .none, false), (90, 72, 3, K.Adapt(gain: SIMD2(0.9, 1.1), bias: 0.04), true),
            (70, 60, 1, K.Adapt(gain: SIMD2(0.8, 1.25), bias: 0.08), false), (80, 64, 4, .none, true),
            (64, 56, 5, K.Adapt(gain: SIMD2(0.67, 1.5), bias: 0.14), true), (160, 120, 3, K.Adapt(gain: SIMD2(0.9, 1.1), bias: 0.04), false),
        ]
        for (w, h, ch, adapt, withRoles) in cases {
            let img = F.busy(w, h, ch, UInt64(w + ch))
            let hole = F.disc(w, h, Float(w) * 0.45, Float(h) * 0.5, Float(min(w, h)) * 0.18)
            let px = withRoles ? F.roles(w, h, hole) : hole.map { $0 ? .hole : .source }
            let p = K.CompleteParams(adapt: adapt, seed: 5)
            let c = try #require(try K.completeMasked(width: w, height: h, channels: ch, image: img, roles: px, params: p, on: .cpu))
            let g = try #require(try K.completeMasked(width: w, height: h, channels: ch, image: img, roles: px, params: p, on: .gpu))
            #expect(F.bits(c) == F.bits(g), "\(w)×\(h)×\(ch) adapt \(adapt) roles \(withRoles)")
        }
        ParityLog.record("Inpaint complete (bits)", 0)
    }

    /// photocraft `completion_fills_blemish_from_texture`.
    @Test func completionFillsBlemishFromTexture() throws {
        let (w, h, ch) = (96, 96, 3)
        let clean = F.texture(w, h)
        let hole = F.disc(w, h, 48, 48, 9)
        var dirty = clean
        for (i, hh) in hole.enumerated() where hh { dirty[(i * ch)..<(i * ch + ch)] = [0.02, 0.02, 0.02] }
        let out = try #require(K.complete(width: w, height: h, channels: ch, image: dirty, hole: hole))
        let before = F.holeRMSE(dirty, clean, hole, ch), after = F.holeRMSE(out, clean, hole, ch)
        #expect(after < 0.06 && after < before * 0.15, "rmse before \(before) after \(after)")
        #expect((0..<(w * h * ch)).allSatisfy { hole[$0 / ch] || out[$0] == dirty[$0] })
        #expect(out == K.complete(width: w, height: h, channels: ch, image: dirty, hole: hole))
    }

    /// photocraft `completion_continues_structure`.
    @Test func completionContinuesStructure() throws {
        let (w, h, ch) = (80, 80, 1)
        let clean: [Float] = (0..<(w * h)).map { (($0 % w) / 4) % 2 == 0 ? 0.2 : 0.8 }
        let hole = F.disc(w, h, 40, 40, 7)
        let dirty = zip(clean, hole).map { $1 ? 0.5 : $0 }
        let out = try #require(K.complete(width: w, height: h, channels: ch, image: dirty, hole: hole))
        let err = F.holeRMSE(out, clean, hole, ch)
        #expect(err < 0.15, "\(err)")
    }

    /// photocraft `proximity_finds_matching_offset`.
    @Test func proximityFindsMatchingOffset() throws {
        let (w, h, ch) = (80, 60, 1)
        let img: [Float] = (0..<(w * h)).map { sinf(Float($0 % w) * PCAMath.tau / 10) * 0.4 + 0.5 }
        let hole = F.disc(w, h, 40, 30, 5)
        let (dx, dy) = try #require(try K.bestOffset(width: w, height: h, channels: ch, image: img, hole: hole, ring: 3, maxRadius: 20))
        #expect(((dx % 10) + 10) % 10 == 0, "dx \(dx) dy \(dy)")
        #expect((dx, dy) != (0, 0))
    }

    /// photocraft `proximity_search_clamps_hostile_radii_without_overflow_or_hanging`.
    @Test func proximitySearchClampsHostileRadii() throws {
        let (w, h, ch) = (24, 20, 1)
        let img: [Float] = (0..<(w * h)).map { Float($0 % w) / Float(w) }
        let hole = F.disc(w, h, 12, 10, 2)
        if let (dx, dy) = try K.bestOffset(width: w, height: h, channels: ch, image: img, hole: hole, ring: Int.max, maxRadius: .max) {
            #expect(abs(dx) <= Int32(w) && abs(dy) <= Int32(h))
        }
        #expect(try K.bestOffset(width: w, height: h, channels: ch, image: img, hole: hole, ring: 2, maxRadius: -1) == nil)
        #expect(try K.bestOffset(width: w, height: h, channels: ch, image: img, hole: hole, ring: 2, maxRadius: 0) == nil)
    }

    /// photocraft `results_do_not_depend_on_the_thread_count`: here, the result is the same run
    /// after run (the parallel passes write disjoint outputs).
    @Test func resultsAreDeterministic() throws {
        let (w, h) = (300, 260)
        for (ch, adapt) in [(3, K.Adapt.none), (4, K.Adapt(gain: SIMD2(0.9, 1.1), bias: 0.04))] {
            let img = F.busy(w, h, ch, 3)
            let hole = F.disc(w, h, 140, 130, 40)
            let px = F.roles(w, h, hole)
            let p = K.CompleteParams(adapt: adapt)
            let a = try #require(try K.completeMasked(width: w, height: h, channels: ch, image: img, roles: px, params: p))
            let b = try #require(try K.completeMasked(width: w, height: h, channels: ch, image: img, roles: px, params: p))
            #expect(F.bits(a) == F.bits(b), "\(ch) channels")
        }
    }

    /// The onion peel as first written: every source in order, every known pixel summed.
    static func onionPeelPlain(_ w: Int, _ h: Int, _ ch: Int, _ r: Int32, _ img: inout [Float], _ px: [K.Px], _ sources: [(Int32, Int32)]) {
        var known = px.map { $0 == .known || $0 == .source }
        let sx = sources.map { Int($0.0) }, sy = sources.map { Int($0.1) }
        let ri = Int(r)
        while true {
            var front: [Int] = []
            for i in 0..<(w * h) where !known[i] && px[i] == .hole {
                let (x, y) = (i % w, i / w)
                var edge = false
                var dy = -1
                while dy <= 1 && !edge {
                    var dx = -1
                    while dx <= 1 {
                        let (nx, ny) = (x + dx, y + dy)
                        if nx >= 0 && ny >= 0 && nx < w && ny < h && known[ny * w + nx] { edge = true; break }
                        dx += 1
                    }
                    dy += 1
                }
                if edge { front.append(i) }
            }
            if front.isEmpty { break }
            var vals = [Float](repeating: 0, count: front.count * ch)
            img.withUnsafeBufferPointer { ib in
                known.withUnsafeBufferPointer { kb in
                    let (im, kn) = (ib.baseAddress!, kb.baseAddress!)
                    for (f, i) in front.enumerated() {
                        let (x, y) = (i % w, i / w)
                        var bestV = Float.infinity, bestJ = -1
                        var j = 0
                        while j < sources.count {
                            var e: Float = 0
                            var n = 0
                            var dy = -ri
                            while dy <= ri {
                                var dx = -ri
                                while dx <= ri {
                                    let (tx, ty) = (x + dx, y + dy)
                                    if tx >= 0 && ty >= 0 && tx < w && ty < h && kn[ty * w + tx] {
                                        let ti = (ty * w + tx) * ch, si = ((sy[j] + dy) * w + (sx[j] + dx)) * ch
                                        var c = 0
                                        while c < ch { let d = im[ti + c] - im[si + c]; e += d * d; c += 1 }
                                        n += 1
                                    }
                                    dx += 1
                                }
                                dy += 1
                            }
                            if n > 0 && e / Float(n) < bestV { bestV = e / Float(n); bestJ = j }
                            j += 1
                        }
                        let si = bestJ < 0 ? 0 : (sy[bestJ] * w + sx[bestJ]) * ch
                        for c in 0..<ch { vals[f * ch + c] = im[si + c] }
                    }
                }
            }
            for (f, i) in front.enumerated() {
                for c in 0..<ch { img[i * ch + c] = vals[f * ch + c] }
                known[i] = true
            }
        }
    }

    static func peel(_ w: Int, _ h: Int, _ ch: Int, _ r: Int32, _ img: inout [Float], _ px: [K.Px], _ sources: [(Int32, Int32)]) throws {
        let hb = try #require(K.holeBounds(w, h, px))
        try img.withUnsafeMutableBufferPointer { ib in
            try px.withUnsafeBufferPointer { pb in
                try K.onionPeel(w, h, ch, r, ib.baseAddress!, pb.baseAddress!, hb, sources, .none)
            }
        }
    }

    /// photocraft `onion_peel_picks_exactly_what_the_plain_scan_picks`.
    @Test func onionPeelPicksExactlyWhatThePlainScanPicks() throws {
        let (w, h, ch, r) = (48, 40, 3, Int32(3))
        var img = F.texture(w, h)
        for y in 0..<h { for x in 6..<(w / 2) { for c in 0..<ch { img[(y * w + x) * ch + c] = img[(y * w + x % 6) * ch + c] } } }
        for hole in [F.disc(w, h, 20, 18, 7.5), F.disc(w, h, 34, 22, 5)] {
            let px: [K.Px] = hole.map { $0 ? .hole : .source }
            let near = K.integral(w, h, hole)
            var sources: [(Int32, Int32)] = []
            for y in r..<(Int32(h) - r) { for x in r..<(Int32(w) - r) where K.windowCount(near, w, h, x - r, y - r, x + r + 1, y + r + 1) == 0 { sources.append((x, y)) } }
            var fast = img, plain = img
            try Self.peel(w, h, ch, r, &fast, px, sources)
            Self.onionPeelPlain(w, h, ch, r, &plain, px, sources)
            #expect(F.bits(fast) == F.bits(plain))
            #expect(fast != img)
        }
    }

    /// photocraft `onion_peel_takes_the_plain_scans_sources`.
    @Test func onionPeelTakesThePlainScansSources() throws {
        for (w, h, ch, seed) in [(44, 36, 1, UInt64(1)), (50, 40, 3, 2), (40, 40, 4, 3)] {
            var img = F.busy(w, h, ch, seed)
            if seed == 3 { img = img.map { ($0 * 3).rounded() / 3 } }
            let hole = F.disc(w, h, Float(w) * 0.45, Float(h) * 0.5, 7.5)
            let px = F.roles(w, h, hole)
            let valid = try K.validSources(w, h, 3, px, .none)
            let sources = K.Sources(valid, w).all(valid, w)
            var a = img, b = img
            try Self.peel(w, h, ch, 3, &a, px, sources)
            Self.onionPeelPlain(w, h, ch, 3, &b, px, sources)
            #expect(F.bits(a) == F.bits(b), "\(w)×\(h)×\(ch)")
        }
    }

    /// photocraft `least_sum_is_where_the_quotient_crosses`.
    @Test func leastSumIsWhereTheQuotientCrosses() {
        var rng = K.Rng(5)
        for i in 0..<4000 {
            let n = Float(1 + rng.next() % 49)
            let v: Float
            switch i % 4 {
            case 0: v = 0
            case 1: v = Float(rng.next() % 1000) * 1e-9
            default: v = Float(rng.next() % 1_000_000) / 1_000_000
            }
            for strict in [true, false] {
                let holds = { (e: Float) in strict ? e / n > v : e / n >= v }
                let e = K.leastSum(v, n, strict)
                #expect(holds(e), "\(v) \(n) \(strict): \(e)")
                #expect(e == 0 || !holds(e.nextDown), "\(v) \(n) \(strict): \(e) is not the least")
            }
        }
        #expect(K.leastSum(.infinity, 4, true) == .infinity)
    }

    /// photocraft `valid_sources_are_the_wholly_copyable_patches`.
    @Test func validSourcesAreTheWhollyCopyablePatches() throws {
        let (w, h, r) = (37, 29, 2)
        var rng = K.Rng(9)
        let px: [K.Px] = (0..<(w * h)).map { _ in
            switch rng.next() % 23 { case 0: .hole; case 1: .void; case 2: .known; default: .source }
        }
        let valid = try K.validSources(w, h, r, px, .none)
        let ss = K.integral(w, h, px.map { $0 == .source })
        let ri = Int32(r), full = UInt32((2 * r + 1) * (2 * r + 1))
        for y in Int32(0)..<Int32(h) {
            for x in Int32(0)..<Int32(w) {
                let inside = x >= ri && y >= ri && x + ri < Int32(w) && y + ri < Int32(h)
                let want = inside && K.windowCount(ss, w, h, x - ri, y - ri, x + ri + 1, y + ri + 1) == full
                #expect(valid[Int(y) * w + Int(x)] == want, "(\(x), \(y))")
            }
        }
        let sources = K.Sources(valid, w)
        let list = sources.all(valid, w)
        #expect(list.count > 10 && list.count == sources.count)
        for (k, p) in list.enumerated() { #expect(sources.nth(k, valid, w) == p) }
        let (w2, h2) = (300, 9)
        let wide: [Bool] = (0..<(w2 * h2)).map { i in (i % w2) % 7 == 3 && (i % w2) / 64 != 2 && i / w2 != 4 }
        let s2 = K.Sources(wide, w2)
        for (k, p) in s2.all(wide, w2).enumerated() { #expect(s2.nth(k, wide, w2) == p) }
    }

    /// photocraft `full_patches_measure_as_clipped_ones`.
    @Test func fullPatchesMeasureAsClippedOnes() throws {
        let (w, h, ch, r) = (46, 38, 4, 3)
        let img = F.busy(w, h, ch, 4)
        let hole = F.disc(w, h, 20, 18, 6)
        let px = F.roles(w, h, hole)
        let hb = try #require(K.holeBounds(w, h, px))
        let tb = hb.grow(r, w, h)
        let valid = try K.validSources(w, h, r, px, .none)
        let all = K.Sources(valid, w).all(valid, w)
        let picks = stride(from: 0, to: all.count, by: 37).map { all[$0] }
        #expect(picks.count > 5)
        for adapt in [K.Adapt.none, K.Adapt(gain: SIMD2(0.8, 1.25), bias: 0.08)] {
            for keep in [false, true] {
                let s = K.Solver(w: w, h: h, ch: ch, r: Int32(r), img: K.Store(img, device: nil), px: K.Store(px, device: nil), valid: valid,
                                 holeBox: hb, tbox: tb, targets: K.targetsAround(w, r, px, hb, tb), adapt: adapt, ctl: .none, gpu: nil)
                s.prepare(keep)
                let nnf = K.Store(tb.area, SIMD2<Int32>(picks[0].0, picks[0].1), device: nil)
                let cost = K.Store(tb.area, Float.infinity, device: nil)
                try s.costs(nnf, cost)
                var checked = 0
                for k in 0..<tb.area where s.targets.ptr[k] && s.full.ptr[k] {
                    let (tx, ty) = (Int32(tb.x0 + k % tb.width), Int32(tb.y0 + k / tb.width))
                    for (sx, sy) in picks {
                        if adapt.isNone {
                            let exact = s.distClipped(tx, ty, sx, sy, .infinity)
                            #expect(s.distFull(tx, ty, sx, sy, .infinity).bitPattern == exact.bitPattern)
                            for cutoff in [exact * 0.5, exact, exact * 2] {
                                #expect((s.distFull(tx, ty, sx, sy, cutoff) < cutoff) == (s.distClipped(tx, ty, sx, sy, cutoff) < cutoff))
                            }
                        } else {
                            var m1 = [SIMD8<Float>](repeating: .zero, count: 8), m2 = m1
                            m1.withUnsafeMutableBufferPointer { s.momentsFull(k, tx, ty, sx, sy, $0.baseAddress!) }
                            let n = m2.withUnsafeMutableBufferPointer { s.moments(tx, ty, sx, sy, $0.baseAddress!) }
                            #expect(n == (2 * r + 1) * (2 * r + 1))
                            #expect(m1.map { $0.bitPatterns } == m2.map { $0.bitPatterns })
                            #expect(s.distAdaptedFull(k, tx, ty, sx, sy).bitPattern == s.distAdapted(tx, ty, sx, sy).bitPattern)
                        }
                        checked += 1
                    }
                }
                #expect(checked > 100, "\(checked)")
            }
        }
    }

    /// photocraft `owned_completion_fills_in_place_or_gives_the_pixels_back`.
    @Test func ownedCompletionFillsInPlaceOrGivesThePixelsBack() throws {
        let (w, h, ch) = (64, 52, 3)
        let img = F.busy(w, h, ch, 6)
        let hole = F.disc(w, h, 30, 26, 8)
        let px = F.roles(w, h, hole)
        let p = K.CompleteParams()
        let borrowed = try #require(try K.completeMasked(width: w, height: h, channels: ch, image: img, roles: px, params: p))
        var owned = img
        #expect(try K.completeMaskedOwned(width: w, height: h, channels: ch, image: &owned, roles: px, params: p))
        #expect(F.bits(owned) == F.bits(borrowed))
        let known: [K.Px] = px.map { $0 == .source ? .known : $0 }
        #expect(try K.completeMasked(width: w, height: h, channels: ch, image: img, roles: known, params: p) == nil)
        var back = img
        let filledBack = try K.completeMaskedOwned(width: w, height: h, channels: ch, image: &back, roles: known, params: p)
        #expect(!filledBack)
        #expect(F.bits(back) == F.bits(img))
        #expect(throws: K.Cancelled.self) {
            var v = img
            _ = try K.completeMaskedOwned(width: w, height: h, channels: ch, image: &v, roles: px, params: p, interrupt: .cancelOnly { true })
        }
    }

    /// photocraft `synthesis_fills_hole_with_plausible_values`.
    @Test func synthesisFillsHoleWithPlausibleValues() {
        let (w, h, ch) = (64, 64, 3)
        let clean = F.texture(w, h)
        let hole = F.disc(w, h, 32, 32, 6)
        let out = K.synthesize(width: w, height: h, channels: ch, image: clean, hole: hole, block: 8, seed: 3)
        #expect(F.holeRMSE(out, clean, hole, ch) < 0.15)
        let finite = out.allSatisfy { $0.isFinite }
        #expect(finite)
    }

    // MARK: photocraft inpaint/proximity_integral/tests.rs

    /// photocraft `cropped_counts_match_full_image_for_clipped_and_disjoint_windows`.
    @Test func croppedCountsMatchFullImage() throws {
        let (w, h) = (37, 29)
        for kind in 0..<5 {
            let hole: [Bool] = (0..<(w * h)).map { i in
                let (x, y) = (i % w, i / w)
                switch kind {
                case 0: return (11..<16).contains(x) && (8..<14).contains(y)
                case 1: return x < 3 && y < 4
                case 2: return x >= w - 3 && y >= h - 4
                case 3: return (x == 3 && y == 8) || (x == 31 && y == 25)
                default: return (x * 37 + y * 71) % 17 == 0
                }
            }
            let bbox = try #require(K.holeBBox(w, h, hole))
            let cropped = try #require(K.HoleIntegral(w, hole, bbox))
            let fullT = K.integral(w, h, hole)
            for x0: Int32 in [-50, -1, 0, 3, 11, 15, 36, 40] {
                for x1: Int32 in [-2, 0, 3, 13, 16, 37, 50] {
                    for y0: Int32 in [-30, -1, 0, 8, 13, 28, 35] {
                        for y1: Int32 in [-1, 0, 10, 14, 29, 40] {
                            #expect(cropped.count(x0, y0, x1, y1) == K.windowCount(fullT, w, h, x0, y0, x1, y1))
                        }
                    }
                }
            }
        }
    }

    /// photocraft `table_size_depends_on_the_hole_bounds`.
    @Test func tableSizeDependsOnTheHoleBounds() throws {
        let (w, h) = (1000, 700)
        let hole: [Bool] = (0..<(w * h)).map { (503..<514).contains($0 % w) && (307..<320).contains($0 / w) }
        let bbox = try #require(K.holeBBox(w, h, hole))
        let table = try #require(K.HoleIntegral(w, hole, bbox))
        #expect(table.w == 11 && table.h == 13 && table.data.count == 12 * 14)
        #expect(table.count(0, 0, 1000, 700) == 143)
        #expect(table.count(.min, .min, .max, .max) == 143)
        #expect(K.HoleIntegral(w, hole, (10, 5, 9, 6)) == nil)
        #expect(K.HoleIntegral(w, [], (3, 4, 5, 6)) == nil)
        #expect(K.HoleIntegral(w, [], (0, 0, Int.max, 2)) == nil)
    }

    /// photocraft's `old_best_offset`: the full search without cropped tables or early outs.
    static func oldBestOffset(_ w: Int, _ h: Int, _ ch: Int, _ img: [Float], _ hole: [Bool], _ ring0: Int, _ maxRadius0: Int32) -> (Int32, Int32)? {
        guard let (bx0, by0, bx1, by1) = K.holeBBox(w, h, hole) else { return nil }
        let extent = Int32(min(max(w, h), Int(Int32.max / 4)))
        let maxRadius = min(max(maxRadius0, 0), extent)
        if maxRadius == 0 { return nil }
        let ring = Int32(min(max(ring0, 1), Int(extent)))
        let hs = K.integral(w, h, hole)
        var all: [SIMD2<Int32>] = []
        let (x0, y0, x1, y1) = (Int32(bx0) - ring, Int32(by0) - ring, Int32(bx1) + ring, Int32(by1) + ring)
        var y = max(y0, 0)
        while y < min(y1, Int32(h)) {
            var x = max(x0, 0)
            while x < min(x1, Int32(w)) {
                if !hole[Int(y) * w + Int(x)] && K.windowCount(hs, w, h, x - ring, y - ring, x + ring + 1, y + ring + 1) > 0 { all.append(SIMD2(x, y)) }
                x += 1
            }
            y += 1
        }
        let st = max(all.count / 2000, 1)
        var pts: [SIMD2<Int32>] = []
        var k = 0
        while k < all.count { pts.append(all[k]); k += st }
        func eval(_ dx: Int32, _ dy: Int32) -> Float? {
            let (hx0, hy0, hx1, hy1) = (x0 + dx, y0 + dy, x1 + dx, y1 + dy)
            let inside = hx0 >= 0 && hy0 >= 0 && hx1 <= Int32(w) && hy1 <= Int32(h)
            if (dx == 0 && dy == 0) || !inside || K.windowCount(hs, w, h, hx0, hy0, hx1, hy1) != 0 { return nil }
            var e: Float = 0
            img.withUnsafeBufferPointer { im in
                var i = 0
                while i < pts.count {
                    let a = (Int(pts[i].y) * w + Int(pts[i].x)) * ch, b = (Int(pts[i].y + dy) * w + Int(pts[i].x + dx)) * ch
                    var c = 0
                    while c < ch { let d = im[a + c] - im[b + c]; e += d * d; c += 1 }
                    i += 1
                }
            }
            return e / Float(max(pts.count, 1)) * (1 + 1e-3 * (hypotf(Float(dx), Float(dy)) / Float(maxRadius)))
        }
        let step = max(maxRadius / 24, 1)
        var has = false
        var bestD = SIMD2<Int32>.zero
        var bestE: Float = 0
        func consider(_ dx: Int32, _ dy: Int32) {
            if let e = eval(dx, dy), !has || e < bestE { has = true; bestD = SIMD2(dx, dy); bestE = e }
        }
        var dy = -maxRadius
        while dy <= maxRadius { var dx = -maxRadius; while dx <= maxRadius { consider(dx, dy); dx += step }; dy += step }
        if step > 1 && has {
            let (bx, by) = (bestD.x, bestD.y)
            var fy = by - step
            while fy <= by + step { var fx = bx - step; while fx <= bx + step { consider(fx, fy); fx += 1 }; fy += 1 }
        }
        return has ? (bestD.x, bestD.y) : nil
    }

    /// photocraft `proximity_offsets_match_full_tables_at_several_depths_and_channels`, on the CPU
    /// and the GPU.
    @Test func proximityOffsetsMatchFullTables() throws {
        let (w, h) = (61, 49)
        let backends: [Backend] = AlgoGPU.isAvailable ? [.cpu, .gpu] : [.cpu]
        for ch in [1, 3, 4, 5] {
            for depth in [8, 16, 32] {
                let img: [Float] = (0..<(w * h * ch)).map { i in
                    let value = Float((i * 101 + i / (w * ch) * 37) % 251) / 250
                    switch depth {
                    case 8: return (value * 255).rounded() / 255
                    case 16: return (value * 65535).rounded() / 65535
                    default: return value * 2 - 0.5
                    }
                }
                for kind in 0..<5 {
                    let hole: [Bool] = (0..<(w * h)).map { i in
                        let (x, y) = (i % w, i / w)
                        switch kind {
                        case 0: return (27..<32).contains(x) && (20..<25).contains(y)
                        case 1: return x < 2 && y < 3
                        case 2: return (x == 11 && y == 12) || (x == 38 && y == 30)
                        case 3: return x == 30 && y == 24
                        default: return false
                        }
                    }
                    for (ring, radius) in [(1, Int32(5)), (3, 17), (5, 30), (1, 49)] {
                        let want = Self.oldBestOffset(w, h, ch, img, hole, ring, radius)
                        for b in backends {
                            let got = try K.bestOffset(width: w, height: h, channels: ch, image: img, hole: hole, ring: ring, maxRadius: radius, on: b)
                            #expect(got?.0 == want?.0 && got?.1 == want?.1, "\(b) ch \(ch) depth \(depth) hole \(kind) ring \(ring) radius \(radius)")
                        }
                    }
                }
            }
        }
    }

    /// photocraft `ties_nonfinite_samples_and_full_holes_keep_the_previous_result`.
    @Test func tiesNonfiniteSamplesAndFullHoles() throws {
        let (w, h, ch) = (40, 35, 3)
        let hole: [Bool] = (0..<(w * h)).map { (18..<22).contains($0 % w) && (16..<20).contains($0 / w) }
        for value: Float in [0.5, .nan, .infinity, -.infinity] {
            let img = [Float](repeating: value, count: w * h * ch)
            let want = Self.oldBestOffset(w, h, ch, img, hole, 3, 20)
            let got = try K.bestOffset(width: w, height: h, channels: ch, image: img, hole: hole, ring: 3, maxRadius: 20)
            #expect(got?.0 == want?.0 && got?.1 == want?.1)
        }
        #expect(try K.bestOffset(width: w, height: h, channels: ch, image: [Float](repeating: 0.5, count: w * h * ch), hole: [Bool](repeating: true, count: w * h), ring: 3, maxRadius: 20) == nil)
    }
}

fileprivate extension SIMD8 where Scalar == Float {
    var bitPatterns: [UInt32] { (0..<8).map { self[$0].bitPattern } }
}
