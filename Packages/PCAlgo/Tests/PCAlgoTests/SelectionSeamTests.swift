// Port of photocraft-algo (crates/algo/src/seam.rs tests), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import Testing
@testable import PCAlgo
import PCFoundation

/// The straightforward implementation photocraft's per-seam carver replaced (full energy map,
/// fresh seam search and a new buffer per seam), kept as the oracle.
enum SeamReference {
    static func energy(_ w: Int, _ h: Int, _ ch: Int, _ img: [Float]) -> [Float] {
        var e = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let xl = x > 0 ? x - 1 : 0, xr = min(x + 1, w - 1), yu = y > 0 ? y - 1 : 0, yd = min(y + 1, h - 1)
                func at(_ xx: Int, _ yy: Int, _ c: Int) -> Float { img[(yy * w + xx) * ch + c] }
                var s: Float = 0
                for c in 0..<ch {
                    let v = at(x, y, c)
                    s += abs(at(xr, y, c) - v) + abs(v - at(xl, y, c))
                    s += abs(at(x, yd, c) - v) + abs(v - at(x, yu, c))
                }
                e[y * w + x] = s * 0.5
            }
        }
        return e
    }

    static func findSeam(_ w: Int, _ h: Int, _ energy: [Float]) -> [Int] {
        var cost = Array(energy[0..<w])
        var from = [UInt8](repeating: 0, count: w * h)
        var next = [Float](repeating: 0, count: w)
        for y in 1..<max(h, 1) {
            for x in 0..<w {
                var best = (cost[x], UInt8(1))
                if x > 0 && cost[x - 1] < best.0 { best = (cost[x - 1], 0) }
                if x + 1 < w && cost[x + 1] < best.0 { best = (cost[x + 1], 2) }
                next[x] = best.0 + energy[y * w + x]
                from[y * w + x] = best.1
            }
            swap(&cost, &next)
        }
        var x = 0
        for i in 1..<max(w, 1) where SelectionKit.totalLess(cost[i], cost[x]) { x = i }
        var seam = [Int](repeating: 0, count: h)
        for y in stride(from: h - 1, through: 0, by: -1) {
            seam[y] = x
            if y > 0 { x = from[y * w + x] == 0 ? x - 1 : (from[y * w + x] == 2 ? x + 1 : x) }
        }
        return seam
    }

    static func removeSeam(_ w: Int, _ h: Int, _ ch: Int, _ img: [Float], _ seam: [Int]) -> [Float] {
        var out: [Float] = []
        for (y, sx) in seam.enumerated() where y < h {
            let row = Array(img[(y * w * ch)..<((y + 1) * w * ch)])
            out.append(contentsOf: row[0..<(sx * ch)])
            out.append(contentsOf: row[((sx + 1) * ch)...])
        }
        return out
    }

    static func carveWidth(_ w: Int, _ h: Int, _ ch: Int, _ img: [Float], _ protect: [Float]?, _ nw: Int) -> [Float] {
        let newW = max(nw, 1)
        if newW == w || w == 0 || h == 0 { return img }
        func protectE(_ e: inout [Float], _ p: [Float]?) {
            if let p { for i in 0..<e.count { e[i] += clampf(p[i], 0, 1) * SeamCarving.protectEnergy } }
        }
        if newW < w {
            var cur = img, cw = w, prot = protect
            while cw > newW {
                var e = energy(cw, h, ch, cur)
                protectE(&e, prot)
                let seam = findSeam(cw, h, e)
                cur = removeSeam(cw, h, ch, cur, seam)
                prot = prot.map { removeSeam(cw, h, 1, $0, seam) }
                cw -= 1
            }
            return cur
        }
        var cur = img, cw = w, prot = protect
        while cw < newW {
            let k = min(newW - cw, max(cw / 2, 1))
            var idx: [[Int]] = (0..<h).map { _ in Array(0..<cw) }
            var tmp = cur, tw = cw, tprot = prot
            var dup = [[Int]](repeating: [], count: h)
            for _ in 0..<k {
                if tw == 0 { break }
                var e = energy(tw, h, ch, tmp)
                protectE(&e, tprot)
                let seam = findSeam(tw, h, e)
                for (y, sx) in seam.enumerated() { dup[y].append(idx[y].remove(at: sx)) }
                tmp = removeSeam(tw, h, ch, tmp, seam)
                tprot = tprot.map { removeSeam(tw, h, 1, $0, seam) }
                tw -= 1
            }
            let added = dup[0].count
            if added == 0 { break }
            var out: [Float] = [], nprot: [Float]? = prot.map { _ in [] }
            for y in 0..<h {
                let d = dup[y].sorted()
                var di = 0
                for x in 0..<cw {
                    let o = (y * cw + x) * ch
                    out.append(contentsOf: cur[o..<(o + ch)])
                    if let p = prot { nprot!.append(p[y * cw + x]) }
                    while di < d.count && d[di] == x {
                        let xr = min(x + 1, cw - 1)
                        for c in 0..<ch { out.append((cur[o + c] + cur[(y * cw + xr) * ch + c]) * 0.5) }
                        if let p = prot { nprot!.append(p[y * cw + x]) }
                        di += 1
                    }
                }
            }
            cur = out; prot = nprot; cw += added
        }
        return cur
    }

    static func carve(_ w: Int, _ h: Int, _ ch: Int, _ img: [Float], _ protect: [Float]?, _ nw: Int, _ nh: Int) -> [Float] {
        let newW = max(nw, 1), newH = max(nh, 1)
        let wide = carveWidth(w, h, ch, img, protect, newW)
        if newH == h { return wide }
        let protT = protect.map { SeamCarving.transpose(newW, h, 1, SeamCarving.resizeBilinear(w: w, h: h, ch: 1, img: $0, newW: newW, newH: h)) }
        let t = SeamCarving.transpose(newW, h, ch, wide)
        let tall = carveWidth(h, newW, ch, t, protT, newH)
        return SeamCarving.transpose(newH, newW, ch, tall)
    }

    /// photocraft's `noise`: xorshift32 values quantised to `levels` (the energy map is full of ties).
    static func noise(_ len: Int, _ levels: UInt32, _ seed: UInt32) -> [Float] {
        var s = seed | 1
        return (0..<len).map { _ in
            s ^= s << 13; s ^= s >> 17; s ^= s << 5
            return Float(s % levels) / Float(levels - 1)
        }
    }

    static func fnv(_ v: [Float]) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for f in v { var b = f.bitPattern.littleEndian; withUnsafeBytes(of: &b) { for byte in $0 { h = (h ^ UInt64(byte)) &* 0x100_0000_01b3 } } }
        return h
    }

    /// A flat grey image with a salient vertical bar at x = 10…13 (red/blue columns).
    static func bar(_ w: Int, _ h: Int) -> [Float] {
        var v = [Float](repeating: 0.5, count: w * h * 3)
        for y in 0..<h {
            for x in 10..<14 {
                let c: [Float] = x % 2 == 0 ? [1, 0, 0] : [0, 0, 1]
                v.replaceSubrange(((y * w + x) * 3)..<((y * w + x) * 3 + 3), with: c)
            }
        }
        return v
    }

    /// Columns that are pure red or pure blue top to bottom.
    static func redColumns(_ w: Int, _ h: Int, _ img: [Float]) -> Int {
        func pure(_ i: Int) -> Bool {
            let p = Array(img[i..<(i + 3)])
            return p[1] < 0.05 && ((p[0] > 0.95 && p[2] < 0.05) || (p[2] > 0.95 && p[0] < 0.05))
        }
        return (0..<w).filter { x in (0..<h).allSatisfy { y in pure((y * w + x) * 3) } }.count
    }
}

@Suite struct SelectionSeamTests {
    /// photocraft `carver_matches_reference`: bit-identical over random shapes, channel counts,
    /// tie-heavy noise, protection, shrinking, enlarging and both axes.
    @Test func carverMatchesReference() {
        var seed: UInt32 = 1
        func next(_ n: Int) -> Int { seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5; return Int(seed) % n }
        for c in 0..<200 {
            let w = 1 + next(24), h = 1 + next(18), ch = [1, 3, 4][next(3)]
            let levels: UInt32 = [2, 5, 255, 65_536][next(4)]
            let img = SeamReference.noise(w * h * ch, levels, 11 + UInt32(c))
            let protect = next(3) == 0 ? SeamReference.noise(w * h, 3, 101 + UInt32(c)) : nil
            let nw = 1 + next(2 * w + 2), nh = 1 + next(2 * h + 2)
            let got = SeamCarving.carve(w: w, h: h, ch: ch, img: img, protect: protect, newW: nw, newH: nh)
            let want = SeamReference.carve(w, h, ch, img, protect, nw, nh)
            #expect(got.map(\.bitPattern) == want.map(\.bitPattern), "case \(c): \(w)x\(h)x\(ch) -> \(nw)x\(nh)")
        }
        for c in 0..<100 {
            let w = 1 + next(40), h = 1 + next(30)
            let e = SeamReference.noise(w * h, [2, 3, 1000][next(3)], 7 + UInt32(c))
            #expect(SeamCarving.findSeam(w: w, h: h, energy: e) == SeamReference.findSeam(w, h, e), "seam case \(c)")
            let img = SeamReference.noise(w * h * 3, 7, 3 + UInt32(c))
            #expect((try? SeamCarving.energy(w: w, h: h, ch: 3, img: img))?.map(\.bitPattern) == SeamReference.energy(w, h, 3, img).map(\.bitPattern))
        }
    }

    /// photocraft `output_bits_are_pinned`: the exact output bits of a spread of carves, as
    /// photocraft pins them (FNV-1a of the Float bits). Matching them shows the port is
    /// bit-identical to the Rust implementation.
    @Test func outputBitsArePinned() {
        let cases: [(Int, Int, Int, UInt32, Bool, Int, Int)] = [
            (61, 47, 3, 2, false, 40, 47), (61, 47, 3, 255, false, 61, 30), (61, 47, 4, 4, true, 35, 29), (33, 20, 1, 3, false, 80, 20),
            (33, 20, 3, 1000, true, 50, 45), (48, 36, 4, 7, false, 70, 18), (5, 3, 1, 2, false, 1, 1), (40, 40, 3, 2, true, 39, 41),
        ]
        let pinned: [UInt64] = [0x24ea_9353_02c2_7c58, 0x5a6e_8554_a0cb_ebb1, 0x8b18_d63f_396e_21c9, 0x1db2_23ad_3e6a_a7c5,
                                0x721d_6cc5_34e0_3fdf, 0x961a_ea6d_e512_ec7d, 0x4d25_767f_9dce_13f5, 0x2157_9f86_27d6_b835]
        for (i, (w, h, ch, levels, prot, nw, nh)) in cases.enumerated() {
            let img = SeamReference.noise(w * h * ch, levels, 7 + UInt32(i))
            let protect = prot ? SeamReference.noise(w * h, 3, 99 + UInt32(i)) : nil
            let out = SeamCarving.carve(w: w, h: h, ch: ch, img: img, protect: protect, newW: nw, newH: nh)
            #expect(out.count == nw * nh * ch)
            #expect(SeamReference.fnv(out) == pinned[i], "case \(i): \(String(SeamReference.fnv(out), radix: 16))")
        }
    }

    /// photocraft `cancelled_carve_stops`.
    @Test func cancelledCarveStops() throws {
        let img = [Float](repeating: 0.5, count: 40 * 20 * 3)
        #expect(throws: CarveCancelled.self) { try SeamCarving.carve(w: 40, h: 20, ch: 3, img: img, protect: nil, newW: 30, newH: 15, control: CarveControl(cancelled: { true })) }
        #expect(try SeamCarving.carve(w: 40, h: 20, ch: 3, img: img, protect: nil, newW: 30, newH: 15, control: .none)
                == SeamCarving.carve(w: 40, h: 20, ch: 3, img: img, protect: nil, newW: 30, newH: 15))
    }

    /// photocraft `seam_follows_low_energy`.
    @Test func seamFollowsLowEnergy() {
        var e = [Float](repeating: 9, count: 5 * 4)
        for y in 0..<4 { e[y * 5 + 2] = 0 }
        #expect(SeamCarving.findSeam(w: 5, h: 4, energy: e) == [2, 2, 2, 2])
    }

    /// photocraft `shrinking_keeps_the_salient_bar` and `enlarging_duplicates_flat_areas`.
    @Test func shrinkingAndEnlargingKeepTheSalientBar() {
        let img = SeamReference.bar(40, 12)
        let out = SeamCarving.carve(w: 40, h: 12, ch: 3, img: img, protect: nil, newW: 24, newH: 12)
        #expect(out.count == 24 * 12 * 3 && SeamReference.redColumns(24, 12, out) == 4)
        #expect(SeamReference.redColumns(24, 12, SeamCarving.resizeBilinear(w: 40, h: 12, ch: 3, img: img, newW: 24, newH: 12)) < 4)
        let big = SeamCarving.carve(w: 30, h: 8, ch: 3, img: SeamReference.bar(30, 8), protect: nil, newW: 50, newH: 8)
        #expect(big.count == 50 * 8 * 3 && SeamReference.redColumns(50, 8, big) == 4)
    }

    /// photocraft `tall_proxy_shrink_preserves_full_resolution_salient_and_protected_pixels`
    /// (narrower than photocraft's 512 → 384 to keep debug runs short; still the proxy path)
    /// and `…_observes_cancellation_before_modifying_source`.
    @Test func tallProxyShrink() throws {
        let (w, h, ch, newW) = (192, SeamCarving.proxyShrinkMinHeight, 3, 120)
        var img = SeamReference.bar(w, h)
        var protect = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            img.replaceSubrange(((y * w + 150) * ch)..<((y * w + 150) * ch + 3), with: [0.03, 0.87, 0.42])
            protect[y * w + 150] = 1
        }
        let out = try SeamCarving.carveWidth(w: w, h: h, ch: ch, img: img, protect: protect, newW: newW, control: .none)
        #expect(out.count == newW * h * ch)
        #expect(SeamReference.redColumns(newW, h, out) == 4, "the full-resolution bar survives")
        for y in 0..<h {
            let row = out[(y * newW * ch)..<((y + 1) * newW * ch)]
            let found = stride(from: row.startIndex, to: row.endIndex, by: 3).contains { Array(row[$0..<($0 + 3)]) == [0.03, 0.87, 0.42] }
            #expect(found, "protected mark survives row \(y)")
            if !found { break }
        }
        #expect(throws: CarveCancelled.self) {
            try SeamCarving.carveWidth(w: 128, h: h, ch: 3, img: [Float](repeating: 0.5, count: 128 * h * 3), protect: nil, newW: 64, control: CarveControl(cancelled: { true }))
        }
    }

    /// photocraft `height_and_protection`.
    @Test func heightAndProtection() {
        let (w, h) = (20, 30)
        var img = [Float](repeating: 0.2, count: w * h)
        for x in 0..<w { img[12 * w + x] = 1 }
        let out = SeamCarving.carve(w: w, h: h, ch: 1, img: img, protect: nil, newW: w, newH: 18)
        #expect(out.count == w * 18)
        #expect((0..<18).filter { y in (0..<w).allSatisfy { out[y * w + $0] > 0.9 } }.count == 1)
        var marked = [Float](repeating: 0.5, count: 16 * 4), protect = [Float](repeating: 0, count: 16 * 4)
        for y in 0..<4 { protect[y * 16 + 3] = 1; marked[y * 16 + 3] = 0.51 }
        let o2 = SeamCarving.carve(w: 16, h: 4, ch: 1, img: marked, protect: protect, newW: 8, newH: 4)
        #expect((0..<4).allSatisfy { y in o2[(y * 8)..<(y * 8 + 8)].contains { abs($0 - 0.51) < 1e-6 } })
    }

    /// photocraft `one_pixel_lines_enlarge_by_repeating`.
    @Test func onePixelLinesEnlargeByRepeating() {
        let col: [Float] = [0.1, 0.2, 0.3, 0.4, 0.5]
        #expect(SeamCarving.carve(w: 1, h: 5, ch: 1, img: col, protect: nil, newW: 4, newH: 5) == col.flatMap { [Float](repeating: $0, count: 4) })
        #expect(SeamCarving.carve(w: 5, h: 1, ch: 1, img: col, protect: nil, newW: 5, newH: 3) == col + col + col)
        let px: [Float] = [0.7, 0.8, 0.9]
        #expect(SeamCarving.carve(w: 1, h: 1, ch: 3, img: px, protect: nil, newW: 3, newH: 2) == (0..<6).flatMap { _ in px })
        for (w, h, nw, nh) in [(1, 5, 6, 10), (1, 17, 6, 34), (16, 1, 21, 2), (7, 1, 3, 8), (2, 1, 1, 8)] {
            let out = SeamCarving.carve(w: w, h: h, ch: 4, img: [Float](repeating: 0.5, count: w * h * 4), protect: [Float](repeating: 1, count: w * h), newW: nw, newH: nh)
            #expect(out.count == nw * nh * 4, "\(w)x\(h) -> \(nw)x\(nh)")
        }
    }

    /// photocraft `skin_rule`.
    @Test func skinRule() {
        #expect(SeamCarving.skinMask(w: 2, h: 1, ch: 3, img: [0.86, 0.62, 0.5, 0.2, 0.4, 0.8]) == [1, 0])
    }

    /// The Metal energy map equals the CPU's bit for bit.
    @Test(.enabled(if: AlgoGPU.isAvailable)) func energyParity() throws {
        var worst: Float = 0
        for (w, h, ch) in [(97, 61, 3), (1, 40, 4), (40, 1, 1), (300, 200, 4)] {
            let img = SeamReference.noise(w * h * ch, 1000, UInt32(w + h))
            let c = try SeamCarving.energy(w: w, h: h, ch: ch, img: img, on: .cpu), g = try SeamCarving.energy(w: w, h: h, ch: ch, img: img, on: .gpu)
            #expect(c.map(\.bitPattern) == g.map(\.bitPattern), "\(w)x\(h)x\(ch)")
            worst = max(worst, SelGPU.maxDiff(c, g))
        }
        ParityLog.record("Seam energy", worst)
    }
}
