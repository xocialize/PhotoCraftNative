// Port of photocraft-algo (crates/algo/src/seam.rs; photocraft-raster's Interrupt), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Content-aware scaling by seam carving (Edit › Content-Aware Scale; Avidan & Shamir, SIGGRAPH
// 2007): a seam is an 8-connected path of one pixel per row found by dynamic programming over a
// gradient-magnitude energy map. Shrinking removes the lowest-energy seams one at a time
// (updating the energy only next to each removed seam); enlarging finds the k lowest seams on a
// shrinking copy and duplicates them (averaged with their right neighbour). Heights go through a
// transpose. A protect map (0…1) adds a large energy so seams avoid it. Buffers are interleaved
// w × h × ch normalised floats of any model and depth. Deterministic, bit-identical to photocraft.
//
// Metal: the energy map (Shaders/SelectionSeam.metal, bit-identical; `.gpu` only — at 2048×1536
// it takes 3.6 ms with the transfers vs 0.9 ms on the CPU). The seam search stays on the CPU:
// each DP row depends on the previous one and each seam on the last removal, so a GPU version is
// a chain of one dispatch per row per seam (1536 dispatches for a seam the CPU finds in 0.6 ms,
// measured in release), and the incremental energy update touches ~3 pixels per row.

import Foundation
import Metal
import PCFoundation

/// A cancellation check and a progress sink (photocraft-raster `Interrupt`).
public struct CarveControl: Sendable {
    public var cancelled: @Sendable () -> Bool
    public var progress: @Sendable (Float) -> Void
    public init(cancelled: @escaping @Sendable () -> Bool = { false }, progress: @escaping @Sendable (Float) -> Void = { _ in }) {
        self.cancelled = cancelled; self.progress = progress
    }
    /// Never cancelled; progress ignored.
    public static let none = CarveControl()
    func check() throws { if cancelled() { throw CarveCancelled() } }
}

/// A carve stopped by its `CarveControl`.
public struct CarveCancelled: Error, Equatable, Sendable {}

/// Content-Aware Scale (photocraft `seam`).
public enum SeamCarving {
    /// Energy added per unit of protection: far above any gradient magnitude.
    static let protectEnergy: Float = 1.0e4
    /// Seams of tall images are searched on rows averaged down to at most this height…
    static let seamSearchMaxHeight = 512
    /// …when the image is at least this tall and at least this many seams go.
    static let proxyShrinkMinHeight = 2048
    static let proxyShrinkMinSeams = 64

    /// Gradient-magnitude energy (|∂x| + |∂y| summed over channels, forward and backward
    /// differences both counted, halved). Metal path: `on: .gpu` (bit-identical; `.auto` is the CPU).
    public static func energy(w: Int, h: Int, ch: Int, img: [Float], on backend: Backend = .cpu) throws -> [Float] {
        if w == 0 || h == 0 { return [Float](repeating: 0, count: w * h) }
        if try Selection.useGPU(backend, w * h) { return try energyGPU(w: w, h: h, ch: ch, img: img) }
        var e = [Float](repeating: 0, count: w * h)
        e.withUnsafeMutableBufferPointer { eb in
            let ep = UnsafeSendable(eb)
            img.withUnsafeBufferPointer { ib in
                parallelChunks(h, minChunk: 8) { rows in
                    for y in rows { for x in 0..<w { ep.value[y * w + x] = energyAt(ib, w, w, h, ch, x, y) } }
                }
            }
        }
        return e
    }

    /// `energy` of one pixel of a `cw`-wide image whose rows are `stride` pixels apart (shared by
    /// the full map and the per-seam updates so both give identical values).
    @inline(__always)
    static func energyAt(_ img: UnsafeBufferPointer<Float>, _ stride: Int, _ cw: Int, _ h: Int, _ ch: Int, _ x: Int, _ y: Int) -> Float {
        let xl = x > 0 ? x - 1 : 0, xr = min(x + 1, cw - 1)
        let yu = y > 0 ? y - 1 : 0, yd = min(y + 1, h - 1)
        @inline(__always) func at(_ xx: Int, _ yy: Int, _ c: Int) -> Float { img[(yy * stride + xx) * ch + c] }
        var s: Float = 0
        for c in 0..<ch {
            let v = at(x, y, c)
            s += abs(at(xr, y, c) - v) + abs(v - at(xl, y, c))
            s += abs(at(x, yd, c) - v) + abs(v - at(x, yu, c))
        }
        return s * 0.5
    }

    /// The lowest-energy vertical seam: one x per row.
    public static func findSeam(w: Int, h: Int, energy: [Float]) -> [Int] {
        if w == 0 || h == 0 || energy.count < w * h { return [Int](repeating: 0, count: h) }
        var dp = Dp()
        return energy.withUnsafeBufferPointer { dp.seam(w, w, h, $0) }
    }

    /// Scratch buffers of the seam search, reused across seams.
    struct Dp {
        var cost: [Float] = []
        var next: [Float] = []
        /// Per pixel, where the cheapest path came from: 0 up-left, 1 up, 2 up-right.
        var from: [UInt8] = []

        /// The lowest-energy seam of a `cw`-wide, `h`-tall map with rows `stride` apart. Ties go
        /// to the pixel straight up, then up-left, then up-right; at the bottom, the leftmost end.
        mutating func seam(_ stride: Int, _ cw: Int, _ h: Int, _ energy: UnsafeBufferPointer<Float>) -> [Int] {
            cost = Array(energy[0..<cw])
            if next.count < cw { next = [Float](repeating: 0, count: cw) }
            if from.count < cw * h { from = [UInt8](repeating: 0, count: cw * h) }
            cost.withUnsafeMutableBufferPointer { cb0 in
                next.withUnsafeMutableBufferPointer { nb0 in
                    from.withUnsafeMutableBufferPointer { fb in
                        var cb = cb0, nb = nb0
                        for y in 1..<max(h, 1) {
                            let e = energy.baseAddress! + y * stride
                            let f = fb.baseAddress! + y * cw
                            if cw == 1 {
                                nb[0] = cb[0] + e[0]; f[0] = 1
                            } else {
                                var (b, d): (Float, UInt8) = cb[1] < cb[0] ? (cb[1], 2) : (cb[0], 1)
                                nb[0] = b + e[0]; f[0] = d
                                for x in 1..<(cw - 1) {
                                    (b, d) = cb[x - 1] < cb[x] ? (cb[x - 1], 0) : (cb[x], 1)
                                    if cb[x + 1] < b { (b, d) = (cb[x + 1], 2) }
                                    nb[x] = b + e[x]; f[x] = d
                                }
                                (b, d) = cb[cw - 2] < cb[cw - 1] ? (cb[cw - 2], 0) : (cb[cw - 1], 1)
                                nb[cw - 1] = b + e[cw - 1]; f[cw - 1] = d
                            }
                            swap(&cb, &nb)
                        }
                        // After an odd number of swaps the costs sit in the `next` buffer.
                        if cb.baseAddress != cb0.baseAddress { for x in 0..<cw { cb0[x] = cb[x] } }
                    }
                }
            }
            var x = 0
            for i in 1..<max(cw, 1) where SelectionKit.totalLess(cost[i], cost[x]) { x = i }
            var seam = [Int](repeating: 0, count: h)
            for y in Swift.stride(from: h - 1, through: 0, by: -1) {
                seam[y] = x
                if y > 0 {
                    switch from[y * cw + x] {
                    case 0: x -= 1
                    case 2: x += 1
                    default: break
                    }
                }
            }
            return seam
        }
    }

    /// Shrinks an image one seam at a time in place (rows keep their stride; the energy is
    /// updated only next to each removed seam) — photocraft `Carver`.
    struct Carver {
        let stride: Int
        var cw: Int
        let h: Int, ch: Int
        var img: [Float]
        var prot: [Float]?
        /// Energy plus protection, as the seam search sees it.
        var e: [Float]
        /// Original column of each pixel, when the caller needs to know which ones went.
        var idx: [Int]?
        var dp = Dp()

        init(_ w: Int, _ h: Int, _ ch: Int, _ img: [Float], _ prot: [Float]?, track: Bool) {
            var e = (try? SeamCarving.energy(w: w, h: h, ch: ch, img: img, on: .cpu)) ?? []
            if let p = prot { for i in 0..<e.count { e[i] += clampf(p[i], 0, 1) * SeamCarving.protectEnergy } }
            self.stride = w; self.cw = w; self.h = h; self.ch = ch; self.img = img; self.prot = prot; self.e = e
            self.idx = track ? (0..<h).flatMap { _ in 0..<w } : nil
        }

        /// Removes the lowest-energy seam; returns, per row, the removed column (original column
        /// when tracking).
        mutating func removeSeam() -> [Int] {
            let (stride, cw, h, ch) = (self.stride, self.cw, self.h, self.ch)
            let seam = e.withUnsafeBufferPointer { dp.seam(stride, cw, h, $0) }
            let removed: [Int]
            if let idx { removed = seam.enumerated().map { idx[$0.offset * stride + $0.element] } } else { removed = seam }
            SeamCarving.shiftRows(&img, stride * ch, seam, ch, cw)
            SeamCarving.shiftRows(&e, stride, seam, 1, cw)
            if prot != nil { SeamCarving.shiftRows(&prot!, stride, seam, 1, cw) }
            if idx != nil { SeamCarving.shiftRows(&idx!, stride, seam, 1, cw) }
            self.cw -= 1
            updateEnergy(seam)
            return removed
        }

        /// Recomputes the energy of the pixels whose neighbours changed: in row y, from one left
        /// of the leftmost seam x of rows y-1…y+1 to the rightmost.
        mutating func updateEnergy(_ seam: [Int]) {
            let (stride, cw, h, ch) = (self.stride, self.cw, self.h, self.ch)
            if cw == 0 { return }
            let prot = self.prot
            img.withUnsafeBufferPointer { ib in
                e.withUnsafeMutableBufferPointer { eb in
                    let ep = UnsafeSendable(eb)
                    parallelChunks(h, minChunk: 64) { rows in
                        for y in rows {
                            let near = seam[(y > 0 ? y - 1 : 0)..<min(y + 2, h)]
                            let lo = max(near.min()! - 1, 0), hi = min(near.max()!, cw - 1)
                            if lo > hi { continue }
                            for x in lo...hi {
                                var v = SeamCarving.energyAt(ib, stride, cw, h, ch, x, y)
                                if let p = prot { v += clampf(p[y * stride + x], 0, 1) * SeamCarving.protectEnergy }
                                ep.value[y * stride + x] = v
                            }
                        }
                    }
                }
            }
        }

        /// The carved pixels, cw × h × ch, rows packed.
        func pixels() -> [Float] {
            let row = stride * ch, used = cw * ch
            if row == used { return img }
            var out: [Float] = []
            out.reserveCapacity(used * h)
            for y in 0..<h { out.append(contentsOf: img[(y * row)..<(y * row + used)]) }
            return out
        }
    }

    /// Removes pixel `seam[y]` (of `n` values) from each `rowLen`-long row whose first `cw` pixels
    /// are in use, by shifting the rest of the row left.
    static func shiftRows<T>(_ buf: inout [T], _ rowLen: Int, _ seam: [Int], _ n: Int, _ cw: Int) {
        buf.withUnsafeMutableBufferPointer { b in
            let bp = UnsafeSendable(b.baseAddress!)
            parallelChunks(seam.count, minChunk: 64) { rows in
                for r in rows {
                    let x = seam[r]
                    let base = bp.value + r * rowLen
                    let count = (cw - x - 1) * n
                    // Forward copy: the destination precedes the source.
                    for i in 0..<max(count, 0) { base[x * n + i] = base[(x + 1) * n + i] }
                }
            }
        }
    }

    static func transpose(_ w: Int, _ h: Int, _ ch: Int, _ img: [Float]) -> [Float] {
        var out = [Float](repeating: 0, count: img.count)
        for y in 0..<h {
            for x in 0..<w {
                let s = (y * w + x) * ch, d = (x * h + y) * ch
                for c in 0..<ch { out[d + c] = img[s + c] }
            }
        }
        return out
    }

    /// Changes the width of `img` to `newW` by removing or duplicating vertical seams.
    public static func carveWidth(w: Int, h: Int, ch: Int, img: [Float], protect: [Float]?, newW: Int) -> [Float] {
        (try? carveWidth(w: w, h: h, ch: ch, img: img, protect: protect, newW: newW, control: .none)) ?? img
    }

    /// `carveWidth` that checks `control` before every seam and reports progress per seam.
    public static func carveWidth(w: Int, h: Int, ch: Int, img: [Float], protect: [Float]?, newW nw: Int, control ctl: CarveControl) throws -> [Float] {
        let newW = max(nw, 1)
        if newW == w || w == 0 || h == 0 { return img }
        let seams = Float(max(abs(newW - w), 1))
        if newW < w {
            if h >= proxyShrinkMinHeight && w - newW >= proxyShrinkMinSeams {
                return try carveWidthProxyHeight(w: w, h: h, ch: ch, img: img, protect: protect, newW: newW, ctl)
            }
            var carver = Carver(w, h, ch, img, protect, track: false)
            while carver.cw > newW {
                try ctl.check()
                ctl.progress(Float(w - carver.cw) / seams)
                _ = carver.removeSeam()
            }
            return carver.pixels()
        }
        // Enlarge in rounds of at most half the current width, each duplicating the k lowest seams.
        var cur = img, cw = w
        var prot = protect
        while cw < newW {
            let k = min(newW - cw, max(cw / 2, 1))
            // Find k seams on a shrinking copy, mapping each back to original columns.
            var carver = Carver(cw, h, ch, cur, prot, track: true)
            var dup = [[Int]](repeating: [], count: h)
            for _ in 0..<k {
                // A 1 px wide image's only seam is its one column: take it, so it is duplicated.
                if carver.cw == 0 { break }
                try ctl.check()
                ctl.progress(Float(max(cw + (cw - carver.cw) - w, 0)) / seams)
                for (y, x) in carver.removeSeam().enumerated() { dup[y].append(x) }
            }
            let added = dup[0].count
            if added == 0 { break }
            let nwid = cw + added
            var out: [Float] = []
            out.reserveCapacity(nwid * h * ch)
            var nprot: [Float]? = prot.map { _ in [] }
            for y in 0..<h {
                let d = dup[y].sorted()
                let row = y * cw * ch
                var di = 0
                for x in 0..<cw {
                    out.append(contentsOf: cur[(row + x * ch)..<(row + x * ch + ch)])
                    if let p = prot { nprot!.append(p[y * cw + x]) }
                    while di < d.count && d[di] == x {
                        let xr = min(x + 1, cw - 1)
                        for c in 0..<ch { out.append((cur[row + x * ch + c] + cur[row + xr * ch + c]) * 0.5) }
                        if let p = prot { nprot!.append(p[y * cw + x]) }
                        di += 1
                    }
                }
            }
            cur = out
            prot = nprot
            cw = nwid
        }
        return cur
    }

    /// Large-image shrink: seams found on vertically averaged rows, then applied (interpolated
    /// between proxy rows) to the full-resolution pixels — photocraft `carve_width_proxy_height`.
    static func carveWidthProxyHeight(w: Int, h: Int, ch: Int, img: [Float], protect: [Float]?, newW: Int, _ ctl: CarveControl) throws -> [Float] {
        let step = (h + seamSearchMaxHeight - 1) / seamSearchMaxHeight
        let proxyH = (h + step - 1) / step
        let rowLen = w * ch
        var proxy = [Float](repeating: 0, count: proxyH * rowLen)
        for py in 0..<proxyH {
            let y0 = py * step, y1 = min(y0 + step, h)
            let divisor = Float(y1 - y0)
            for y in y0..<y1 {
                for i in 0..<rowLen { proxy[py * rowLen + i] += img[y * rowLen + i] / divisor }
            }
        }
        let proxyProtect: [Float]? = protect.map { mask in
            var reduced = [Float](repeating: 0, count: proxyH * w)
            for py in 0..<proxyH {
                let y0 = py * step, y1 = min(y0 + step, h)
                let divisor = Float(y1 - y0)
                for y in y0..<y1 { for i in 0..<w { reduced[py * w + i] += mask[y * w + i] / divisor } }
            }
            return reduced
        }
        let seamCount = w - newW
        var carver = Carver(w, proxyH, ch, proxy, proxyProtect, track: true)
        var removed: [[Int]] = []
        removed.reserveCapacity(seamCount)
        while carver.cw > newW {
            try ctl.check()
            removed.append(carver.removeSeam())
            ctl.progress(Float(removed.count) / Float(seamCount))
        }
        let removedByRow: [[Int]] = (0..<proxyH).map { py in removed.map { $0[py] }.sorted() }
        var out: [Float] = []
        out.reserveCapacity(newW * h * ch)
        var columns = [Int](repeating: 0, count: seamCount)
        for y in 0..<h {
            try ctl.check()
            let proxyY = min(y / step, proxyH - 1)
            let nextY = min(proxyY + 1, proxyH - 1)
            let blend = Float(y % step) / Float(step)
            let lower = removedByRow[proxyY], upper = removedByRow[nextY]
            var minX = 0
            for i in 0..<seamCount {
                let interpolated = Float(lower[i]) + (Float(upper[i]) - Float(lower[i])) * blend
                let maxX = w - (seamCount - i)
                columns[i] = min(max(SelectionKit.usizeCast(interpolated.rounded()), minX), maxX)
                minX = columns[i] + 1
            }
            var next = 0
            for x in 0..<w {
                if next < seamCount && columns[next] == x { next += 1 } else { out.append(contentsOf: img[(y * rowLen + x * ch)..<(y * rowLen + x * ch + ch)]) }
            }
        }
        ctl.progress(1)
        return out
    }

    /// Content-aware resize of `img` to newW × newH (width first, then height by transposing).
    public static func carve(w: Int, h: Int, ch: Int, img: [Float], protect: [Float]?, newW: Int, newH: Int) -> [Float] {
        (try? carve(w: w, h: h, ch: ch, img: img, protect: protect, newW: newW, newH: newH, control: .none)) ?? img
    }

    /// `carve` that checks `control` before every seam and reports progress over both passes.
    public static func carve(w: Int, h: Int, ch: Int, img: [Float], protect: [Float]?, newW nw: Int, newH nh: Int, control ctl: CarveControl) throws -> [Float] {
        let newW = max(nw, 1), newH = max(nh, 1)
        // Split progress between the passes by their seam counts.
        let sw = Float(abs(newW - w)), sh = Float(abs(newH - h))
        let split: Float = sw + sh > 0 ? sw / (sw + sh) : 1
        let first = CarveControl(cancelled: ctl.cancelled, progress: { f in ctl.progress(f * split) })
        let wide = try carveWidth(w: w, h: h, ch: ch, img: img, protect: protect, newW: newW, control: first)
        if newH == h { return wide }
        // Protection follows the width change by plain resampling (it only steers seams).
        let protT = protect.map { transpose(newW, h, 1, resizeBilinear(w: w, h: h, ch: 1, img: $0, newW: newW, newH: h)) }
        let t = transpose(newW, h, ch, wide)
        let second = CarveControl(cancelled: ctl.cancelled, progress: { f in ctl.progress(split + f * (1 - split)) })
        let tall = try carveWidth(w: h, h: newW, ch: ch, img: t, protect: protT, newW: newH, control: second)
        return transpose(newH, newW, ch, tall)
    }

    /// Plain bilinear resize (the non-content-aware part of the Amount blend).
    public static func resizeBilinear(w: Int, h: Int, ch: Int, img: [Float], newW nw: Int, newH nh: Int) -> [Float] {
        var out = [Float](repeating: 0, count: nw * nh * ch)
        if w == 0 || h == 0 { return out }
        for y in 0..<nh {
            let fy = clampf((Float(y) + 0.5) * Float(h) / Float(nh) - 0.5, 0, Float(h - 1))
            let y0 = Int(fy.rounded(.down)), ty = fy - fy.rounded(.towardZero)
            let y1 = min(y0 + 1, h - 1)
            for x in 0..<nw {
                let fx = clampf((Float(x) + 0.5) * Float(w) / Float(nw) - 0.5, 0, Float(w - 1))
                let x0 = Int(fx.rounded(.down)), tx = fx - fx.rounded(.towardZero)
                let x1 = min(x0 + 1, w - 1)
                for c in 0..<ch {
                    @inline(__always) func p(_ xx: Int, _ yy: Int) -> Float { img[(yy * w + xx) * ch + c] }
                    let top = p(x0, y0) + (p(x1, y0) - p(x0, y0)) * tx
                    let bot = p(x0, y1) + (p(x1, y1) - p(x0, y1)) * tx
                    out[(y * nw + x) * ch + c] = top + (bot - top) * ty
                }
            }
        }
        return out
    }

    /// Skin-tone protection map (1 = skin) for RGB(A) buffers: the explicit RGB rule of Kovač,
    /// Peer & Solina, EUROCON 2003.
    public static func skinMask(w: Int, h: Int, ch: Int, img: [Float]) -> [Float] {
        var m = [Float](repeating: 0, count: w * h)
        if ch < 3 { return m }
        for i in 0..<(w * h) {
            let r = img[i * ch] * 255, g = img[i * ch + 1] * 255, b = img[i * ch + 2] * 255
            let mx = Float.maximum(Float.maximum(r, g), b), mn = Float.minimum(Float.minimum(r, g), b)
            if r > 95 && g > 40 && b > 20 && mx - mn > 15 && abs(r - g) > 15 && r > g && r > b { m[i] = 1 }
        }
        return m
    }

    // MARK: Metal energy

    struct EnergyParams: BitwiseCopyable { var w: UInt32; var h: UInt32; var ch: UInt32; var pad0: UInt32 = 0 }

    static func energyGPU(w: Int, h: Int, ch: Int, img: [Float]) throws -> [Float] {
        let ib = try SelectionKit.GPU.buffer(img), out = try SelectionKit.GPU.zeros(w * h, of: Float.self)
        try SelectionKit.GPU.run("seam energy") { e in
            try e.dispatch("pca_sel_seam_energy", EnergyParams(w: UInt32(w), h: UInt32(h), ch: UInt32(ch)), [ib, out], w, h)
        }
        return SelectionKit.GPU.read(out, w * h, as: Float.self)
    }
}
