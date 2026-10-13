// Port of photocraft-algo (crates/algo/src/selection/distance/tests.rs, selection_blur.rs tests, selection.rs modifier tests), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import Testing
@testable import PCAlgo
import PCFoundation

enum ModifyTest {
    static func brute(_ inside: [Bool], _ w: Int, _ h: Int) -> [Float] {
        let sites = inside.enumerated().filter { $0.element }.map { ($0.offset % w, $0.offset / w) }
        return (0..<(w * h)).map { i in
            var best = Selection.emptyDistance
            for (x, y) in sites {
                let dx = Double(i % w) - Double(x), dy = Double(i / w) - Double(y)
                best = min(best, Float((dx * dx + dy * dy).squareRoot()))
            }
            return best
        }
    }

    /// photocraft's `old_dt1` / `old_edt` (the previous Float transform), kept as an oracle.
    static func oldDT1(_ f: [Float], _ out: inout [Float], _ v: inout [Int], _ z: inout [Float]) {
        let n = f.count
        var k = 0
        v[0] = 0; z[0] = -.infinity; z[1] = .infinity
        if n > 1 {
            for q in 1..<n {
                while true {
                    let p = v[k]
                    let s = ((f[q] + Float(q * q)) - (f[p] + Float(p * p))) / (2 * (Float(q) - Float(p)))
                    if s <= z[k] && k > 0 { k -= 1; continue }
                    if s <= z[k] { v[0] = q; z[0] = -.infinity; z[1] = .infinity; break }
                    k += 1; v[k] = q; z[k] = s; z[k + 1] = .infinity
                    break
                }
            }
        }
        k = 0
        for q in 0..<n {
            while z[k + 1] < Float(q) { k += 1 }
            let d = Float(q) - Float(v[k])
            out[q] = d * d + f[v[k]]
        }
    }

    static func oldEDT(_ inside: [Bool], _ w: Int, _ h: Int) -> [Float] {
        var g: [Float] = inside.map { $0 ? 0 : 1e20 }
        let n = max(w, h, 1)
        var v = [Int](repeating: 0, count: n), z = [Float](repeating: 0, count: n + 1)
        for x in 0..<w {
            let f = (0..<h).map { g[$0 * w + x] }
            var o = [Float](repeating: 0, count: h)
            oldDT1(f, &o, &v, &z)
            for y in 0..<h { g[y * w + x] = o[y] }
        }
        for y in 0..<h {
            let f = Array(g[(y * w)..<(y * w + w)])
            var o = [Float](repeating: 0, count: w)
            oldDT1(f, &o, &v, &z)
            for x in 0..<w { g[y * w + x] = o[x].squareRoot() }
        }
        return g
    }

    static func square(_ w: Int, _ h: Int) -> [Float] {
        (0..<(w * h)).map { (5..<15).contains($0 % w) && (5..<15).contains($0 / w) ? 1 : 0 }
    }

    static func rect64() -> [Float] {
        (0..<(64 * 64)).map { (16..<48).contains($0 % 64) && (16..<48).contains($0 / 64) ? 1 : 0 }
    }

    /// The direct box / Gaussian implementations photocraft keeps as oracles.
    static func boxBlur(_ m: [Float], _ w: Int, _ h: Int, _ r: Int) -> [Float] {
        if r == 0 { return m }
        var tmp = [Float](repeating: 0, count: m.count)
        let win = Float(2 * r + 1)
        for y in 0..<h {
            for x in 0..<w {
                var s: Float = 0
                for k in (x - r)...(x + r) { s += m[y * w + min(max(k, 0), w - 1)] }
                tmp[y * w + x] = s / win
            }
        }
        var out = [Float](repeating: 0, count: m.count)
        for y in 0..<h {
            for x in 0..<w {
                var s: Float = 0
                for k in (y - r)...(y + r) { s += tmp[min(max(k, 0), h - 1) * w + x] }
                out[y * w + x] = s / win
            }
        }
        return out
    }

    static func smoothOracle(_ m: [Float], _ w: Int, _ h: Int, _ r: Float) -> [Float] {
        boxBlur(m, w, h, Int(max(r, 0).rounded())).map { $0 >= 0.5 ? 1 : 0 }
    }

    static func featherOracle(_ m: [Float], _ w: Int, _ h: Int, _ radius: Float) -> [Float] {
        let sigma = max(radius, 0)
        if sigma < 0.1 { return m }
        let r = Int((sigma * 3).rounded(.up))
        let k0: [Float] = (-r...r).map { expf(Float(-($0 * $0)) / (2 * sigma * sigma)) }
        let s = k0.reduce(0, +)
        let k = k0.map { $0 / s }
        var tmp = [Float](repeating: 0, count: m.count)
        for y in 0..<h {
            for x in 0..<w {
                var a: Float = 0
                for (i, kv) in k.enumerated() { let xx = x + i - r; if xx >= 0 && xx < w { a += m[y * w + xx] * kv } }
                tmp[y * w + x] = a
            }
        }
        var out = [Float](repeating: 0, count: m.count)
        for y in 0..<h {
            for x in 0..<w {
                var a: Float = 0
                for (i, kv) in k.enumerated() { let yy = y + i - r; if yy >= 0 && yy < h { a += tmp[yy * w + x] * kv } }
                out[y * w + x] = a
            }
        }
        return out
    }

    static func maxDiff(_ a: [Float], _ b: [Float]) -> Float {
        precondition(a.count == b.count)
        return zip(a, b).map { abs($0 - $1) }.max() ?? 0
    }

    /// photocraft's `masks`: binary noise, soft noise, a soft-edged blob, a sparse scatter, an off-centre rectangle.
    static func masks(_ w: Int, _ h: Int, _ seed: UInt64) -> [(String, [Float])] {
        var rng = SelTest.Rng(seed)
        let binary: [Float] = (0..<(w * h)).map { _ in rng.unit() < 0.5 ? 1 : 0 }
        let soft: [Float] = (0..<(w * h)).map { _ in rng.unit() }
        let cx = Float(w) * rng.unit(), cy = Float(h) * rng.unit(), rad = max(Float(min(w, h)) * 0.4, 1)
        let blob: [Float] = (0..<(w * h)).map { i in
            let x = Float(i % w) + 0.5, y = Float(i / w) + 0.5
            return clampf(rad - ((x - cx) * (x - cx) + (y - cy) * (y - cy)).squareRoot(), 0, 1)
        }
        let sparse: [Float] = (0..<(w * h)).map { _ in rng.unit() < 0.02 ? 1 : 0 }
        let rect: [Float] = (0..<(w * h)).map { i in (i % w) * 3 >= w && (i / w) * 4 < h * 3 ? 1 : 0 }
        return [("binary", binary), ("soft", soft), ("blob", blob), ("sparse", sparse), ("rect", rect)]
    }
}

@Suite struct SelectionModifyTests {
    // MARK: Distance transform

    /// photocraft `matches_brute_force_for_every_small_mask`.
    @Test func edtMatchesBruteForceForEverySmallMask() throws {
        for (w, h) in [(1, 1), (1, 8), (8, 1), (3, 3), (4, 3)] {
            for bits in 0..<(1 << (w * h)) {
                let inside = (0..<(w * h)).map { bits & (1 << $0) != 0 }
                #expect(try Selection.edt(inside, w: w, h: h, on: .cpu) == ModifyTest.brute(inside, w, h), "\(w)x\(h): \(bits)")
            }
        }
    }

    /// photocraft `rectangular_and_partial_bands_match_the_previous_transform` (sizes trimmed).
    @Test func edtMatchesThePreviousTransform() throws {
        for (w, h) in [(1, 101), (101, 1), (17, 33), (73, 65), (9, 255)] {
            for kind in 0..<4 {
                let inside: [Bool] = (0..<(w * h)).map { i in
                    switch kind {
                    case 0: return false
                    case 1: return true
                    case 2: return i == 0 || i == w * h - 1
                    default: return (i * 101 + i / w * 37) % 29 == 0
                    }
                }
                #expect(try Selection.edt(inside, w: w, h: h, on: .cpu) == ModifyTest.oldEDT(inside, w, h), "\(w)x\(h) kind \(kind)")
            }
        }
    }

    /// photocraft `large_coordinates_keep_nearby_parabolas_distinct`.
    @Test func edtLargeCoordinatesKeepNearbyParabolasDistinct() throws {
        for (w, h) in [(65_537, 2), (2, 65_537)] {
            var inside = [Bool](repeating: false, count: w * h)
            if w > h { inside[w - 3] = true; inside[w - 2] = true; inside[2 * w - 1] = true } else {
                inside[(h - 3) * w] = true; inside[(h - 2) * w] = true; inside[h * w - 1] = true
            }
            #expect(try Selection.edt(inside, w: w, h: h, on: .cpu) == ModifyTest.brute(inside, w, h))
            if AlgoGPU.isAvailable { #expect(try Selection.edt(inside, w: w, h: h, on: .gpu) == ModifyTest.brute(inside, w, h)) }
        }
    }

    /// photocraft `selected_pixels_stay_at_zero_past_coordinate_4096` and the empty / inconsistent cases.
    @Test func edtEdgeCases() throws {
        #expect(try Selection.edt([Bool](repeating: true, count: 6000), w: 6000, h: 1, on: .cpu) == [Float](repeating: 0, count: 6000))
        for (mask, w, h) in [([Bool](), 0, 0), ([], 1, 0), ([], 0, 1), ([], 1, 1), ([true], 2, 1), ([true, false], 1, 1), ([], Int.max, 2)] {
            #expect(try Selection.edt(mask, w: w, h: h, on: .cpu).isEmpty)
        }
        #expect(try Selection.edt([false, false], w: 2, h: 1, on: .cpu) == [1e10, 1e10])
    }

    /// photocraft `selection_modifiers_keep_fractional_coverage`.
    @Test func modifiersKeepFractionalCoverage() throws {
        let (w, h) = (47, 39)
        let m: [Float] = (0..<(w * h)).map { (8..<31).contains($0 % w) && (5..<27).contains($0 / w) ? 0.8 : 0.2 }
        func referenceExpand(_ m: [Float], _ r: Float) -> [Float] {
            zip(m, ModifyTest.oldEDT(m.map { $0 >= 0.5 }, w, h)).map { v, d in max(v, clampf(r + 1 - d, 0, 1)) }
        }
        for r: Float in [0, 1, 1.25, 3.75, 16] {
            #expect(try Selection.expand(m, w: w, h: h, r: r, on: .cpu) == referenceExpand(m, r))
            #expect(try Selection.contract(m, w: w, h: h, r: r, on: .cpu) == referenceExpand(m.map { 1 - $0 }, r).map { 1 - $0 })
        }
    }

    /// photocraft `expand_contract_border`.
    @Test func expandContractBorder() throws {
        let m = ModifyTest.square(20, 20)
        let e = try Selection.expand(m, w: 20, h: 20, r: 2, on: .cpu)
        #expect(e[10 * 20 + 3] == 1 && e[10 * 20 + 2] == 0)
        let c = try Selection.contract(m, w: 20, h: 20, r: 2, on: .cpu)
        #expect(c[10 * 20 + 6] == 0 && c[10 * 20 + 7] == 1)
        let b = try Selection.border(m, w: 20, h: 20, r: 4, on: .cpu)
        #expect(b[10 * 20 + 10] == 0 && b[10 * 20 + 5] > 0.5 && b[10 * 20 + 4] > 0.5)
    }

    /// photocraft `border_matches_photoshop` (Photoshop 27.11, Border 4 on a 32 px square).
    @Test func borderMatchesPhotoshop() throws {
        let b = try Selection.border(ModifyTest.rect64(), w: 64, h: 64, r: 4, on: .cpu)
        let v = { (x: Int, y: Int) in Int((b[y * 64 + x] * 255).rounded()) }
        let row = (8...24).map { v($0, 32) }, diag = (16...24).map { v($0, $0) }
        let near = { (g: [Int], w: [Int]) in zip(g, w).allSatisfy { abs($0 - $1) <= 1 } }
        #expect(near(row, [0, 0, 0, 0, 63, 127, 191, 255, 255, 191, 127, 63, 0, 0, 0, 0, 0]), "\(row)")
        #expect(near(diag, [255, 191, 127, 63, 0, 0, 0, 0, 0]), "\(diag)")
    }

    // MARK: Smooth and feather

    /// photocraft `smooth_removes_specks_and_feather_softens`.
    @Test func smoothRemovesSpecksAndFeatherSoftens() throws {
        var m = ModifyTest.square(20, 20)
        m[2 * 20 + 2] = 1
        let s = try Selection.smooth(m, w: 20, h: 20, r: 1, on: .cpu)
        #expect(s[2 * 20 + 2] == 0 && s[10 * 20 + 10] == 1)
        let f = try Selection.feather(ModifyTest.square(20, 20), w: 20, h: 20, radius: 2, on: .cpu)
        #expect(f[10 * 20 + 5] > 0.3 && f[10 * 20 + 5] < 0.8)
        #expect(abs(f.reduce(0, +) - 100) < 1)
    }

    /// photocraft `feather_matches_photoshop` (Photoshop 27.11, Feather 4 on a 32 px square).
    @Test func featherMatchesPhotoshop() throws {
        let row: [Int] = [7, 13, 22, 34, 50, 70, 92, 115, 140, 163, 185, 205, 221, 233, 242, 248, 252]
        let f = try Selection.feather(ModifyTest.rect64(), w: 64, h: 64, radius: 4, on: .cpu)
        let v = { (x: Int, y: Int) in Int((f[y * 64 + x] * 255).rounded()) }
        for (i, want) in row.enumerated() { #expect(abs(v(8 + i, 32) - want) <= 3, "x \(8 + i): \(v(8 + i, 32)) vs \(want)") }
        for (d, want) in [(16, 76), (18, 134), (20, 190)] { #expect(abs(v(d, d) - want) <= 4, "(\(d),\(d)): \(v(d, d)) vs \(want)") }
    }

    /// photocraft `feather_matches_direct_gaussian` (radii up to 120; the cosine series above 12).
    @Test func featherMatchesDirectGaussian() throws {
        for (w, h, seed) in [(97, 61, UInt64(1)), (40, 150, 2), (13, 7, 3)] {
            for (kind, m) in ModifyTest.masks(w, h, seed) {
                for radius: Float in [0.1, 0.3, 1, 2.5, 8, 13, 17, 30] {
                    let d = ModifyTest.maxDiff(try Selection.feather(m, w: w, h: h, radius: radius, on: .cpu), ModifyTest.featherOracle(m, w, h, radius))
                    #expect(d <= 1 / 255, "\(kind) \(w)x\(h) r \(radius): \(d)")
                }
            }
        }
    }

    /// photocraft `smooth_matches_photoshop` (Photoshop 27.11, Smooth 8: straight edges stay, corners round).
    @Test func smoothMatchesPhotoshop() throws {
        let s = try Selection.smooth(ModifyTest.rect64(), w: 64, h: 64, r: 8, on: .cpu)
        let row: [Float] = (8...24).map { s[32 * 64 + $0] }
        let wantRow: [Float] = (8...24).map { $0 >= 16 ? Float(1) : Float(0) }
        let diag: [Float] = (16...24).map { s[$0 * 64 + $0] }
        let wantDiag: [Float] = [0, 0, 0, 0, 1, 1, 1, 1, 1]
        #expect(row == wantRow)
        #expect(diag == wantDiag)
    }

    /// photocraft `smooth_matches_direct_box`.
    @Test func smoothMatchesDirectBox() throws {
        for (w, h, seed) in [(97, 61, UInt64(4)), (40, 150, 5), (13, 7, 6)] {
            for (kind, m) in ModifyTest.masks(w, h, seed) {
                for radius: Float in [0, 0.4, 1, 2, 5, 16, 70] {
                    let fast = try Selection.smooth(m, w: w, h: h, r: radius, on: .cpu), slow = ModifyTest.smoothOracle(m, w, h, radius)
                    let avg = ModifyTest.boxBlur(m, w, h, Int(max(radius, 0).rounded()))
                    for i in 0..<fast.count where fast[i] != slow[i] {
                        #expect(abs(avg[i] - 0.5) < 1e-4, "\(kind) \(w)x\(h) r \(radius) pixel \(i)")
                    }
                }
            }
        }
    }

    /// photocraft `edge_cases` (selection_blur).
    @Test func blurEdgeCases() throws {
        let z = [Float](repeating: 0, count: 50 * 40)
        #expect(try Selection.feather(z, w: 50, h: 40, radius: 30, on: .cpu) == z)
        #expect(try Selection.smooth(z, w: 50, h: 40, r: 10, on: .cpu) == z)
        var dot = z
        dot[20 * 50 + 25] = 1
        let f = try Selection.feather(dot, w: 50, h: 40, radius: 4, on: .cpu)
        #expect(f[0] == 0 && f[20 * 50 + 25] > 0)
        let one = [Float](repeating: 1, count: 50 * 40)
        #expect(try Selection.smooth(one, w: 50, h: 40, r: 25, on: .cpu) == one)
        let f6 = try Selection.feather(one, w: 50, h: 40, radius: 6, on: .cpu)
        #expect(abs(f6[20 * 50 + 25] - 1) < 1e-5 && f6[0] < 0.5)
        #expect(ModifyTest.maxDiff(try Selection.feather(one, w: 50, h: 40, radius: 30, on: .cpu), ModifyTest.featherOracle(one, 50, 40, 30)) <= 1 / 255)
        #expect(ModifyTest.maxDiff(f6, ModifyTest.featherOracle(one, 50, 40, 6)) <= 1 / 255)
        let m: [Float] = (0..<(50 * 40)).map { Float($0 % 7) / 6 }
        #expect(try Selection.feather(m, w: 50, h: 40, radius: 0, on: .cpu) == m)
        #expect(try Selection.smooth(m, w: 50, h: 40, r: 0, on: .cpu) == ModifyTest.smoothOracle(m, 50, 40, 0))
        for r: Float in [0, 1, 50, 1000] {
            #expect(abs(try Selection.feather([1], w: 1, h: 1, radius: r, on: .cpu)[0] - ModifyTest.featherOracle([1], 1, 1, r)[0]) <= 1 / 255)
            #expect(try Selection.smooth([1], w: 1, h: 1, r: r, on: .cpu) == [1])
        }
        #expect(try Selection.feather([], w: 0, h: 0, radius: 5, on: .cpu).isEmpty)
        #expect(try Selection.smooth([], w: 0, h: 5, r: 5, on: .cpu).isEmpty)
        for r in [Float.nan, .infinity, -.infinity, -5, 1e30] {
            let f = try Selection.feather(dot, w: 50, h: 40, radius: r, on: .cpu)
            #expect(f.count == dot.count && f.allSatisfy(\.isFinite), "\(r)")
            #expect(try Selection.smooth(dot, w: 50, h: 40, r: r, on: .cpu).count == dot.count)
        }
        #expect(try Selection.feather(dot, w: 50, h: 41, radius: 5, on: .cpu).count == dot.count)
        #expect(try Selection.smooth(dot, w: 49, h: 40, r: 5, on: .cpu).count == dot.count)
    }

    /// photocraft `cosine_fit_is_used_and_accurate`.
    @Test func cosineFitIsUsed() {
        for sigma: Double in [7, 25, 125] {
            let r = Int((sigma * 3).rounded(.up))
            if case .cos = SelectionKit.Blur.Kernel(sigma: sigma, r: r, n: 4000) {} else { Issue.record("σ \(sigma): expected the cosine kernel") }
        }
    }
}
