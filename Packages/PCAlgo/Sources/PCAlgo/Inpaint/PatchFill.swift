// Port of Compositor's multi-scale PatchMatch fill (PixelAgencyEditor ee08430: Sources/EditorPixelKernels/PatchPixels.c
// `patch_fill`, and HealPixels.c `heal_membrane`), MIT, © 2026 Wonder Assembly LLC.
//
// Multi-scale PatchMatch completion (Wexler, Shechtman & Irani 2007; Barnes et al. 2009), as Compositor's Spot
// Healing ran it for Content-Aware. Every pixel whose 7 × 7 patch touches the hole is a target, matched to the
// source patch (wholly on known pixels) it most resembles; each hole pixel becomes the blend of what the target
// patches covering it say, closer matches counting for more, and that is repeated, first on a small copy (where an
// edge runs through the hole settles there) and then on each copy twice the size. Patches are compared on texture
// as well as colour (Newson et al. 2014): how much edge there is around each pixel, across and down, so the early
// blurred guess doesn't match the plainest parts of the image. The last blend favours the best matches, and the
// fill's tone is fitted to its edge with a membrane.
//
// It differs from `completeMasked` in those three things (texture channels, the sharp last vote, the edge-tone
// membrane), which is what carries a curved edge through a spot (AB-T-0299).

import Dispatch
import Foundation

extension InpaintKit {
    /// Patch radius (7 × 7 patches).
    static let pfR = 3
    /// How much texture counts against colour.
    static let pfTextureWeight: Float = 6
    /// How strongly the last blend favours the best matches (see `PatchFillLevel.vote`).
    static let pfSharpFinish: Float = 8
    static let pfFar = Float.greatestFiniteMagnitude

    /// Fills `hole` in the interleaved `w × h × n` buffer `image` from the rest of it, Compositor's Content-Aware
    /// way (see the file's header). Known pixels are those outside the hole that are opaque (`alpha`'s channel at
    /// 1; every pixel without `alpha`); other pixels outside the hole are left alone and ignored. It works on the
    /// hole and the image around it, at most the hole's larger side (64 px at least) away.
    ///
    /// Returns the buffer with the hole filled (colour isn't clamped above; alpha is clamped to 0…1); unchanged
    /// when the hole is empty; nil when no 7 × 7 patch of known pixels is left to copy from.
    public static func patchFill(width w: Int, height h: Int, channels n: Int, image: [Float], hole: [Bool], alpha: Int? = nil,
                                 seed: UInt32 = 1) -> [Float]? {
        precondition(w >= 0 && h >= 0 && n > 0 && image.count == w * h * n && hole.count == w * h)
        let alpha = alpha.flatMap { $0 < n ? $0 : nil }
        var (x0, y0, x1, y1) = (w, h, 0, 0)
        for y in 0..<h {
            for x in 0..<w where hole[y * w + x] {
                x0 = min(x0, x); x1 = max(x1, x + 1); y0 = min(y0, y); y1 = max(y1, y + 1)
            }
        }
        if x1 <= x0 { return image }
        let size = max(x1 - x0, y1 - y0), margin = max(size, 64)
        let bx0 = max(x0 - margin, 0), by0 = max(y0 - margin, 0), bx1 = min(x1 + margin, w), by1 = min(y1 + margin, h)

        let fine = PatchFillLevel(w: bx1 - bx0, h: by1 - by0, n: n, alpha: alpha)
        for y in 0..<fine.h {
            for x in 0..<fine.w {
                let s = ((by0 + y) * w + bx0 + x) * n, p = y * fine.w + x
                fine.hole[p] = hole[(by0 + y) * w + bx0 + x]
                fine.known[p] = !fine.hole[p] && alpha.map { image[s + $0] >= 1 - 1e-6 } ?? !fine.hole[p]
                for c in 0..<n { fine.color[p * fine.ch + c] = image[s + c] * 255 }
            }
        }
        fine.classify()
        fine.measureTexture()
        if fine.sources.isEmpty { return nil }
        var levels = [fine]
        // Halved until the hole is a couple of patches across, or the image too small to hold sources.
        let side = 2 * pfR + 1
        var span = size
        while span > 4 * side && levels.count < 12 {
            let f = levels[levels.count - 1]
            if f.w < 8 * side || f.h < 8 * side { break }
            let c = f.downsampled()
            if c.sources.isEmpty { break }
            levels.append(c)
            span /= 2
        }
        let coarsest = levels[levels.count - 1]
        coarsest.fillInward()
        coarsest.matchRandomly(seed)
        coarsest.measure()
        coarsest.settle(12, seed)
        for i in stride(from: levels.count - 2, through: 0, by: -1) {
            let l = levels[i]
            l.upsample(from: levels[i + 1], seed &+ UInt32(i))
            l.measure()
            l.vote(1)
            l.measure()
            l.settle(i == 0 ? 4 : 6, seed &+ 0x1000 &* UInt32(i + 1))
        }
        fine.vote(pfSharpFinish)
        fine.adaptColor()
        var out = image
        for y in 0..<fine.h {
            for x in 0..<fine.w {
                let p = y * fine.w + x
                if !fine.hole[p] { continue }
                let d = ((by0 + y) * w + bx0 + x) * n
                for c in 0..<n {
                    let v = fine.color[p * fine.ch + c] / 255
                    out[d + c] = c == alpha ? min(max(v, 0), 1) : max(v, 0)
                }
            }
        }
        return out
    }

    /// Smooths the values of the pixels marked 2 in `role`, fixed to those marked 1 around them (0: neither): the
    /// membrane that makes healed texture meet its surroundings' tone. `value` holds `n` floats a pixel; a coarser
    /// copy is solved first and used as the starting point, so a large area settles in few passes (Compositor's
    /// `heal_membrane`, SOR at ω = 1.8).
    static func pfMembrane(_ value: UnsafeMutablePointer<Float>, _ role: UnsafePointer<UInt8>, _ w: Int, _ h: Int, _ n: Int, _ depth: Int) {
        var iterations = 300
        if w > 32 && h > 32 && depth < 16 {
            let cw = (w + 1) / 2, chh = (h + 1) / 2
            let coarse = UnsafeMutablePointer<Float>.allocate(capacity: cw * chh * n)
            coarse.initialize(repeating: 0, count: cw * chh * n)
            let coarseRole = UnsafeMutablePointer<UInt8>.allocate(capacity: cw * chh)
            coarseRole.initialize(repeating: 0, count: cw * chh)
            defer { coarse.deallocate(); coarseRole.deallocate() }
            var knownSum = [Float](repeating: 0, count: n), holeSum = [Float](repeating: 0, count: n)
            for y in 0..<chh {
                for x in 0..<cw {
                    var known = 0, hole = 0
                    for c in 0..<n { knownSum[c] = 0; holeSum[c] = 0 }
                    for j in 0..<2 {
                        for i in 0..<2 {
                            let fx = x * 2 + i, fy = y * 2 + j
                            if fx >= w || fy >= h { continue }
                            let p = fy * w + fx
                            if role[p] == 1 { known += 1; for c in 0..<n { knownSum[c] += value[p * n + c] } }
                            else if role[p] == 2 { hole += 1; for c in 0..<n { holeSum[c] += value[p * n + c] } }
                        }
                    }
                    let q = y * cw + x
                    if known > 0 { coarseRole[q] = 1; for c in 0..<n { coarse[q * n + c] = knownSum[c] / Float(known) } }
                    else if hole > 0 { coarseRole[q] = 2; for c in 0..<n { coarse[q * n + c] = holeSum[c] / Float(hole) } }
                }
            }
            pfMembrane(coarse, coarseRole, cw, chh, n, depth + 1)
            for y in 0..<h {
                for x in 0..<w {
                    let p = y * w + x, q = (y / 2) * cw + x / 2
                    if role[p] == 2 && coarseRole[q] == 2 { for c in 0..<n { value[p * n + c] = coarse[q * n + c] } }
                }
            }
            iterations = 40
        }
        let omega: Float = 1.8
        var sum = [Float](repeating: 0, count: n)
        for _ in 0..<iterations {
            for y in 0..<h {
                for x in 0..<w {
                    let p = y * w + x
                    if role[p] != 2 { continue }
                    for c in 0..<n { sum[c] = 0 }
                    var k = 0
                    for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] {
                        if nx < 0 || ny < 0 || nx >= w || ny >= h { continue }
                        let q = ny * w + nx
                        if role[q] == 0 { continue }
                        for c in 0..<n { sum[c] += value[q * n + c] }
                        k += 1
                    }
                    if k == 0 { continue }
                    for c in 0..<n { value[p * n + c] += omega * (sum[c] / Float(k) - value[p * n + c]) }
                }
            }
        }
    }
}

/// One size of `InpaintKit.patchFill`'s pyramid: colour (the image's `n` channels, 0…255) and two texture channels
/// per pixel; the hole holds its current estimate. Its buffers are written by row bands that never touch the same
/// pixel, so it is handed to concurrent loops as it is.
final class PatchFillLevel: @unchecked Sendable {
    let w: Int, h: Int, n: Int, ch: Int
    let alpha: Int?
    let color: UnsafeMutablePointer<Float>
    /// To fill.
    let hole: UnsafeMutablePointer<Bool>
    /// Opaque and outside the hole: matched against and copied from.
    let known: UnsafeMutablePointer<Bool>
    /// A patch centred here lies wholly on known pixels.
    let source: UnsafeMutablePointer<Bool>
    /// A patch centred here touches the hole.
    let target: UnsafeMutablePointer<Bool>
    /// Per target: pixels of its patch that count (known or hole).
    let counts: UnsafeMutablePointer<Int32>
    /// Per target: the source centre its patch matches, and the mean squared difference to it.
    let match: UnsafeMutablePointer<Int>
    let distance: UnsafeMutablePointer<Float>
    /// Every source centre, for random picks.
    var sources: [Int] = []

    static let r = InpaintKit.pfR
    static let far = InpaintKit.pfFar

    init(w: Int, h: Int, n: Int, alpha: Int?) {
        self.w = w; self.h = h; self.n = n; self.ch = n + 2; self.alpha = alpha
        let count = w * h
        color = .allocate(capacity: count * (n + 2)); color.initialize(repeating: 0, count: count * (n + 2))
        hole = .allocate(capacity: count); hole.initialize(repeating: false, count: count)
        known = .allocate(capacity: count); known.initialize(repeating: false, count: count)
        source = .allocate(capacity: count); source.initialize(repeating: false, count: count)
        target = .allocate(capacity: count); target.initialize(repeating: false, count: count)
        counts = .allocate(capacity: count); counts.initialize(repeating: 0, count: count)
        match = .allocate(capacity: count); match.initialize(repeating: 0, count: count)
        distance = .allocate(capacity: count); distance.initialize(repeating: Self.far, count: count)
    }

    deinit {
        color.deallocate(); hole.deallocate(); known.deallocate(); source.deallocate(); target.deallocate()
        counts.deallocate(); match.deallocate(); distance.deallocate()
    }

    /// Runs `body(band, rows)` over the rows split into bands, all at once. The bands, and so the results, don't
    /// depend on the scheduling.
    func inRowBands(_ body: (Int, Range<Int>) -> Void) {
        let bands = h < 32 ? 1 : 16, size = (h + bands - 1) / bands
        withoutActuallyEscaping(body) { b in
            nonisolated(unsafe) let run = b
            DispatchQueue.concurrentPerform(iterations: bands) { i in
                let start = i * size, end = min(start + size, h)
                if start < end { run(i, start..<end) }
            }
        }
    }

    @inline(__always) static func nextRandom(_ state: inout UInt32) -> UInt32 {
        var x = state
        x ^= x << 13; x ^= x >> 17; x ^= x << 5
        state = x != 0 ? x : 0x9e37_79b9
        return state
    }

    /// Sources, targets and the pixel counts behind each target's distance, from `hole` and `known`.
    func classify() {
        let stride = w + 1, r = Self.r
        var knownSAT = [Int](repeating: 0, count: stride * (h + 1)), holeSAT = knownSAT
        for y in 0..<h {
            var kr = 0, hr = 0
            for x in 0..<w {
                kr += known[y * w + x] ? 1 : 0; hr += hole[y * w + x] ? 1 : 0
                knownSAT[(y + 1) * stride + x + 1] = knownSAT[y * stride + x + 1] + kr
                holeSAT[(y + 1) * stride + x + 1] = holeSAT[y * stride + x + 1] + hr
            }
        }
        func sum(_ t: [Int], _ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) -> Int {
            t[y1 * stride + x1] - t[y0 * stride + x1] - t[y1 * stride + x0] + t[y0 * stride + x0]
        }
        sources = []
        let full = (2 * r + 1) * (2 * r + 1)
        for y in 0..<h {
            for x in 0..<w {
                let p = y * w + x
                let x0 = max(x - r, 0), y0 = max(y - r, 0), x1 = min(x + r + 1, w), y1 = min(y + r + 1, h)
                let holes = sum(holeSAT, x0, y0, x1, y1)
                target[p] = holes > 0
                counts[p] = Int32(holes + sum(knownSAT, x0, y0, x1, y1))
                let inside = x >= r && y >= r && x + r < w && y + r < h
                source[p] = inside && sum(knownSAT, x - r, y - r, x + r + 1, y + r + 1) == full
                if source[p] { sources.append(p) }
            }
        }
    }

    /// Mean squared difference between the target patch at `p` and the source patch at `q`, over the target's
    /// pixels that count. Gives up, returning `far`, once it can't beat `best`.
    @inline(__always) func patchDistance(_ p: Int, _ q: Int, _ best: Float) -> Float {
        let r = Self.r, ch = ch
        let px = p % w, py = p / w, qx = q % w, qy = q / w
        let count = Float(counts[p])
        let limit = best == Self.far ? Self.far : best * count
        var sum: Float = 0
        for dy in -r...r {
            let y = py + dy
            if y < 0 || y >= h { continue }
            let row = color + (qy + dy) * w * ch
            for dx in -r...r {
                let x = px + dx
                if x < 0 || x >= w { continue }
                let a = y * w + x
                if !(hole[a] || known[a]) { continue }
                let t = color + a * ch, s = row + (qx + dx) * ch
                for c in 0..<ch { let d = t[c] - s[c]; sum += d * d }
            }
            if sum >= limit { return Self.far }
        }
        return counts[p] > 0 ? sum / count : Self.far
    }

    /// One PatchMatch sweep over every target, forward or backward. Each band of rows works on its own; a
    /// neighbour in another band is read from `before` (where the sweep started), so no two bands touch the same
    /// match.
    func patchmatchPass(_ forward: Bool, _ seed: UInt32, _ before: UnsafePointer<Int>) {
        let step = forward ? 1 : -1, reach = max(w, h), w = w, h = h
        inRowBands { band, rows in
            var state = seed ^ (UInt32(truncatingIfNeeded: band) &* 0x9e37_79b9) ^ 0x85eb_ca6b
            for i in 0..<rows.count {
                let y = forward ? rows.lowerBound + i : rows.upperBound - 1 - i
                for j in 0..<w {
                    let x = forward ? j : w - 1 - j, p = y * w + x
                    if !target[p] { continue }
                    var best = match[p], bestDistance = distance[p]
                    // What the previous pixel along the row and the previous row matched, moved along by one.
                    let nx = x - step, ny = y - step
                    if nx >= 0 && nx < w && target[y * w + nx] {
                        let m = match[y * w + nx], c = m + step
                        if m % w + step >= 0 && m % w + step < w && source[c] && c != best {
                            let d = patchDistance(p, c, bestDistance)
                            if d < bestDistance { best = c; bestDistance = d }
                        }
                    }
                    if ny >= 0 && ny < h && target[ny * w + x] {
                        let m = rows.contains(ny) ? match[ny * w + x] : before[ny * w + x], c = m + step * w
                        if m / w + step >= 0 && m / w + step < h && source[c] && c != best {
                            let d = patchDistance(p, c, bestDistance)
                            if d < bestDistance { best = c; bestDistance = d }
                        }
                    }
                    // Then patches at random around the best so far, nearer each time.
                    var r = reach
                    while r >= 1 {
                        defer { r /= 2 }
                        let bx = best % w, by = best / w
                        let cx = bx + Int(Self.nextRandom(&state) % UInt32(2 * r + 1)) - r
                        let cy = by + Int(Self.nextRandom(&state) % UInt32(2 * r + 1)) - r
                        if cx < 0 || cy < 0 || cx >= w || cy >= h { continue }
                        let c = cy * w + cx
                        if !source[c] || c == best { continue }
                        let d = patchDistance(p, c, bestDistance)
                        if d < bestDistance { best = c; bestDistance = d }
                    }
                    match[p] = best
                    distance[p] = bestDistance
                }
            }
        }
    }

    /// The spread of the blend weights: twice the mean distance of the matched targets, plus one.
    func spread() -> Float {
        var total = 0.0, count = 0
        for p in 0..<(w * h) where target[p] && distance[p] < Self.far { total += Double(distance[p]); count += 1 }
        return 2 * Float(count > 0 ? total / Double(count) : 1) + 1
    }

    /// What the matches say the first `k` channels of the pixel at (x, y) should be, blended with `spread`; false
    /// when no match covers it.
    @inline(__always) func predict(_ x: Int, _ y: Int, _ spread: Float, _ k: Int, _ out: UnsafeMutablePointer<Float>) -> Bool {
        let r = Self.r
        for c in 0..<k { out[c] = 0 }
        var weights: Float = 0
        for dy in -r...r {
            let py = y - dy
            if py < 0 || py >= h { continue }
            for dx in -r...r {
                let px = x - dx
                if px < 0 || px >= w { continue }
                let p = py * w + px
                if !target[p] || distance[p] == Self.far { continue }
                let q = match[p]
                let s = color + ((q / w + dy) * w + q % w + dx) * ch
                let weight = expf(-distance[p] / spread)
                for c in 0..<k { out[c] += s[c] * weight }
                weights += weight
            }
        }
        if weights <= 0 { return false }
        for c in 0..<k { out[c] /= weights }
        return true
    }

    /// Each hole pixel becomes the blend of what every target patch covering it says it is, a closer match
    /// counting for more, by `sharpness`: 1 while the matches settle; more for the last blend, where the best
    /// matches all but decide alone, as averaging patches that disagree smears busy texture. Sources lie wholly
    /// outside the hole, so the hole can be rewritten as it's read.
    func vote(_ sharpness: Float) {
        let spread = spread() / sharpness, ch = ch, w = w
        inRowBands { _, rows in
            let out = UnsafeMutablePointer<Float>.allocate(capacity: ch)
            defer { out.deallocate() }
            for y in rows {
                for x in 0..<w where hole[y * w + x] {
                    if predict(x, y, spread, ch, out) { for c in 0..<ch { color[(y * w + x) * ch + c] = out[c] } }
                }
            }
        }
    }

    /// Matches the surroundings' tone, as the healing brush does: copied texture can come from somewhere a little
    /// lighter or darker (further along a sky's gradient), which leaves a visible rim. Along the hole's edge, the
    /// difference between the image and what the matches predict there is spread smoothly across the hole and
    /// added.
    func adaptColor() {
        let count = w * h, spread = spread()
        var role = [UInt8](repeating: 0, count: count)
        var offset = [Float](repeating: 0, count: count * n)
        var mean = [Double](repeating: 0, count: n)
        var edges = 0
        let predicted = UnsafeMutablePointer<Float>.allocate(capacity: n)
        defer { predicted.deallocate() }
        for y in 0..<h {
            for x in 0..<w {
                let p = y * w + x
                if hole[p] { role[p] = 2; continue }
                if !known[p] { continue }
                var touches = false
                for j in -1...1 where !touches {
                    for i in -1...1 {
                        let qx = x + i, qy = y + j
                        if qx >= 0 && qy >= 0 && qx < w && qy < h && hole[qy * w + qx] { touches = true; break }
                    }
                }
                if !touches || !predict(x, y, spread, n, predicted) { continue }
                role[p] = 1
                for c in 0..<n {
                    offset[p * n + c] = color[p * ch + c] - predicted[c]
                    mean[c] += Double(offset[p * n + c])
                }
                edges += 1
            }
        }
        if edges == 0 { return }
        for p in 0..<count where role[p] == 2 { for c in 0..<n { offset[p * n + c] = Float(mean[c] / Double(edges)) } }
        offset.withUnsafeMutableBufferPointer { o in
            role.withUnsafeBufferPointer { InpaintKit.pfMembrane(o.baseAddress!, $0.baseAddress!, w, h, n, 0) }
        }
        for p in 0..<count where role[p] == 2 { for c in 0..<n { color[p * ch + c] += offset[p * n + c] } }
    }

    /// Distances for every target's current match.
    func measure() {
        let w = w
        inRowBands { _, rows in
            for p in (rows.lowerBound * w)..<(rows.upperBound * w) where target[p] {
                distance[p] = patchDistance(p, match[p], Self.far)
            }
        }
    }

    /// The matching and blending, `iterations` times over.
    func settle(_ iterations: Int, _ seed: UInt32) {
        let before = UnsafeMutablePointer<Int>.allocate(capacity: w * h)
        defer { before.deallocate() }
        for i in 0..<iterations {
            before.update(from: match, count: w * h)
            patchmatchPass(i % 2 == 0, seed &+ UInt32(i) &* 0x632b_e5ab, before)
            vote(1)
            measure()
        }
    }

    /// Mean of the colour channels (alpha left out).
    @inline(__always) func luma(_ q: Int) -> Float {
        var s: Float = 0, k = 0
        for c in 0..<n where c != alpha { s += color[q * ch + c]; k += 1 }
        return k > 0 ? s / Float(k) : 0
    }

    /// Each known pixel's texture: how sharply its brightness changes across and down, averaged over the 5 × 5
    /// around it, in the two channels after its colour. Hole pixels get theirs from what they copy.
    func measureTexture() {
        let stride = w + 1
        var edge = [Float](repeating: 0, count: w * h * 2)
        for y in 0..<h {
            for x in 0..<w {
                let p = y * w + x
                if !known[p] { continue }
                if x > 0 && x + 1 < w && known[p - 1] && known[p + 1] { edge[p * 2] = abs(luma(p + 1) - luma(p - 1)) / 2 }
                if y > 0 && y + 1 < h && known[p - w] && known[p + w] { edge[p * 2 + 1] = abs(luma(p + w) - luma(p - w)) / 2 }
            }
        }
        // Summed tables of the two edges and of how many known pixels there are, for 5 × 5 averages over known
        // pixels.
        var sat = [Double](repeating: 0, count: stride * (h + 1) * 3)
        for y in 0..<h {
            var row = (0.0, 0.0, 0.0)
            for x in 0..<w {
                let p = y * w + x
                row.0 += Double(edge[p * 2]); row.1 += Double(edge[p * 2 + 1]); row.2 += known[p] ? 1 : 0
                let a = ((y + 1) * stride + x + 1) * 3, b = (y * stride + x + 1) * 3
                sat[a] = sat[b] + row.0; sat[a + 1] = sat[b + 1] + row.1; sat[a + 2] = sat[b + 2] + row.2
            }
        }
        for y in 0..<h {
            for x in 0..<w {
                let p = y * w + x
                if !known[p] { continue }
                let x0 = max(x - 2, 0), y0 = max(y - 2, 0), x1 = min(x + 3, w), y1 = min(y + 3, h)
                func v(_ k: Int) -> Double {
                    sat[(y1 * stride + x1) * 3 + k] - sat[(y0 * stride + x1) * 3 + k] - sat[(y1 * stride + x0) * 3 + k] + sat[(y0 * stride + x0) * 3 + k]
                }
                let knownHere = v(2)
                color[p * ch + n] = Float(v(0) / knownHere) * InpaintKit.pfTextureWeight
                color[p * ch + n + 1] = Float(v(1) / knownHere) * InpaintKit.pfTextureWeight
            }
        }
    }

    /// A copy half the size: a pixel is hole if any of its four is, known if all of them are. Texture stays as
    /// measured at full size, averaged down, rather than measured again: shrunk, busy texture blurs to a plain
    /// mid-tone, which would match the plainest parts of the image and fill the hole flat.
    func downsampled() -> PatchFillLevel {
        let cw = (w + 1) / 2, chh = (h + 1) / 2, ch = ch
        let c = PatchFillLevel(w: cw, h: chh, n: n, alpha: alpha)
        var all = [Float](repeating: 0, count: ch), sure = all
        for y in 0..<chh {
            for x in 0..<cw {
                var present = 0, knownCount = 0, isHole = false
                for k in 0..<ch { all[k] = 0; sure[k] = 0 }
                for j in 0..<2 {
                    for i in 0..<2 {
                        let fx = 2 * x + i, fy = 2 * y + j
                        if fx >= w || fy >= h { continue }
                        let f = fy * w + fx
                        present += 1; isHole = isHole || hole[f]
                        if known[f] { knownCount += 1 }
                        for k in 0..<ch {
                            all[k] += color[f * ch + k]
                            if known[f] { sure[k] += color[f * ch + k] }
                        }
                    }
                }
                let p = y * cw + x
                c.hole[p] = isHole
                c.known[p] = !isHole && knownCount == present
                for k in 0..<ch { c.color[p * ch + k] = knownCount > 0 ? sure[k] / Float(knownCount) : all[k] / Float(present) }
            }
        }
        c.classify()
        return c
    }

    /// The coarsest hole's first guess: filled in from its edge inward, each pixel the average of the filled
    /// neighbours around it, and whatever no edge reaches the average of the known image.
    func fillInward() {
        let count = w * h
        var done = (0..<count).map { known[$0] }
        var mean = [Double](repeating: 0, count: ch)
        var knownCount = 0
        for p in 0..<count where known[p] { knownCount += 1; for c in 0..<ch { mean[c] += Double(color[p * ch + c]) } }
        var sum = [Float](repeating: 0, count: ch)
        var changed = true
        while changed {
            changed = false
            var next = done
            for y in 0..<h {
                for x in 0..<w {
                    let p = y * w + x
                    if !hole[p] || done[p] { continue }
                    for c in 0..<ch { sum[c] = 0 }
                    var around = 0
                    for j in -1...1 {
                        for i in -1...1 {
                            let qx = x + i, qy = y + j
                            if (i != 0 || j != 0) && qx >= 0 && qy >= 0 && qx < w && qy < h && done[qy * w + qx] {
                                for c in 0..<ch { sum[c] += color[(qy * w + qx) * ch + c] }
                                around += 1
                            }
                        }
                    }
                    if around == 0 { continue }
                    for c in 0..<ch { color[p * ch + c] = sum[c] / Float(around) }
                    next[p] = true; changed = true
                }
            }
            done = next
        }
        for p in 0..<count where hole[p] && !done[p] {
            for c in 0..<ch { color[p * ch + c] = knownCount > 0 ? Float(mean[c] / Double(knownCount)) : 0 }
        }
    }

    func matchRandomly(_ seed: UInt32) {
        var state = seed | 1
        for p in 0..<(w * h) where target[p] { match[p] = sources[Int(Self.nextRandom(&state) % UInt32(sources.count))] }
    }

    /// This copy starts where the coarser one finished: its hole from the coarser estimate, each target's match
    /// from the coarser match, scaled up.
    func upsample(from c: PatchFillLevel, _ seed: UInt32) {
        var state = seed | 1
        for y in 0..<h {
            for x in 0..<w {
                let p = y * w + x, q = (y / 2) * c.w + x / 2
                if hole[p] { (color + p * ch).update(from: c.color + q * ch, count: ch) }
                if !target[p] { continue }
                var candidate = -1
                if c.target[q] {
                    let m = c.match[q], mx = 2 * (m % c.w) + (x & 1), my = 2 * (m / c.w) + (y & 1)
                    if mx < w && my < h && source[my * w + mx] { candidate = my * w + mx }
                }
                match[p] = candidate >= 0 ? candidate : sources[Int(Self.nextRandom(&state) % UInt32(sources.count))]
            }
        }
    }
}
