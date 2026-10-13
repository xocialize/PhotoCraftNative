// Port of photocraft-algo (crates/algo/src/resample.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// One separable resampling pass (photocraft `resize_pass`): the horizontal taps run over each
// premultiplied source row, the vertical taps sum the horizontal rows into bands of 64 output rows,
// the default pixel fills taps outside the content, alpha is clipped to 0…1 and the result
// unpremultiplied. Source rows stream through in bounded reads (tile rows with nothing stored count
// as rows of the default pixel without being read), so a huge sparse surface never needs a dense
// window. The same tap tables drive the Metal pass (`ResampleKit.PassFilter`), which runs the
// horizontal taps into an intermediate texture and the vertical taps from it.

import Foundation
import Metal
import PCFoundation

/// Pixels a resampling pass reads: a surface (sparse tiles, default pixel) or a dense image.
protocol ResampleSource {
    var channels: Int { get }
    var defaultPixel: [Float] { get }
    /// Whether `r` may hold anything but the default pixel (photocraft `has_tiles_in`).
    func hasData(in r: PixelRect) -> Bool
    /// Reads `r` (default pixel where nothing is stored) into `buf`, resized to `r.area × channels`.
    func read(_ r: PixelRect, into buf: inout [Float])
}

extension ResampleKit {
    /// A surface as a resampling source.
    struct SurfaceSource: ResampleSource {
        let surface: Surface
        let defaultPixel: [Float]
        init(_ s: Surface) { surface = s; defaultPixel = s.defaultPixelValue }
        var channels: Int { surface.channels }
        func hasData(in r: PixelRect) -> Bool {
            if r.isEmpty { return false }
            return r.tiles.contains { surface.tile($0) != nil }
        }
        /// Only stored tiles are decoded; the rest is the default pixel.
        func read(_ r: PixelRect, into buf: inout [Float]) {
            let n = surface.channels, count = r.area * n
            if buf.count != count { buf = [Float](repeating: 0, count: count) }
            var part: [Float] = []
            buf.withUnsafeMutableBufferPointer { d in
                ResampleKit.fill(d, with: defaultPixel)
                for c in r.tiles where surface.tile(c) != nil {
                    let tr = c.rect.intersect(r)
                    if part.count != tr.area * n { part = [Float](repeating: 0, count: tr.area * n) }
                    surface.readRegion(tr, into: &part)
                    part.withUnsafeBufferPointer { s in
                        let span = tr.width * n
                        for y in tr.y0..<tr.y1 {
                            let di = (Int(y - r.y0) * r.width + Int(tr.x0 - r.x0)) * n
                            (d.baseAddress! + di).update(from: s.baseAddress! + Int(y - tr.y0) * span, count: span)
                        }
                    }
                }
            }
        }
    }

    /// Fills `d` with repeats of `px` (doubling copies).
    static func fill(_ d: UnsafeMutableBufferPointer<Float>, with px: [Float]) {
        let n = px.count, count = d.count
        if count == 0 || n == 0 { return }
        if px.allSatisfy({ $0.bitPattern == 0 }) { d.update(repeating: 0); return }
        let base = d.baseAddress!
        for c in 0..<min(n, count) { base[c] = px[c] }
        var filled = min(n, count)
        while filled < count {
            let k = min(filled, count - filled)
            (base + filled).update(from: base, count: k)
            filled += k
        }
    }

    /// A dense image as a resampling source: the default pixel outside its rectangle.
    struct ImageSource: ResampleSource {
        let image: FloatImage
        let defaultPixel: [Float]
        var channels: Int { image.channels }
        func hasData(in r: PixelRect) -> Bool { !r.intersect(image.rect).isEmpty }
        func read(_ r: PixelRect, into buf: inout [Float]) {
            let n = image.channels, count = r.area * n
            if buf.count != count { buf = [Float](repeating: 0, count: count) }
            let inner = r.intersect(image.rect)
            buf.withUnsafeMutableBufferPointer { d in
                if inner != r { ResampleKit.fill(d, with: defaultPixel) }
                if inner.isEmpty { return }
                image.data.withUnsafeBufferPointer { s in
                    let span = inner.width * n
                    for y in inner.y0..<inner.y1 {
                        let si = (Int(y - image.rect.y0) * image.rect.width + Int(inner.x0 - image.rect.x0)) * n
                        let di = (Int(y - r.y0) * r.width + Int(inner.x0 - r.x0)) * n
                        (d.baseAddress! + di).update(from: s.baseAddress! + si, count: span)
                    }
                }
            }
        }
    }

    /// Everything a pass needs besides the pixels: output rectangle, tap tables and read window.
    struct PassGeometry: Hashable, Codable, Sendable {
        /// The output rectangle (`scaled_rect` of the content).
        var dst: PixelRect
        /// Rows/columns taps may read (the edge area, else the content).
        var area: PixelRect
        var hx: [Taps]
        var vy: [Taps]
        /// Columns the horizontal taps read: `[xLo, xHi)`.
        var xLo: Int32
        var xHi: Int32
        /// Rows the vertical taps read: `[yLo, yHi)` (the union of every band's window).
        var yLo: Int32
        var yHi: Int32
        /// The default pixel, straight and premultiplied.
        var def: [Float]
        var defPremul: [Float]
    }

    /// The geometry of one pass over `content` (photocraft `resize_pass` set-up); nil when the
    /// output is empty. With `canvas`, the content and the canvas repeat their edge outwards.
    static func prepare(content src: PixelRect, defaultPixel: [Float], alpha: Bool, pass: Pass, canvas: PixelRect?) -> PassGeometry? {
        let edgeU = canvas.map { src.union($0) }
        let edge = (edgeU?.isEmpty ?? true) ? nil : edgeU
        let dst = Resample.scaledRect(src, sx: pass.sx, sy: pass.sy)
        if dst.isEmpty { return nil }
        // With `edge`, every tap is clamped into the edge area, which holds the content.
        let area = edge ?? src
        let hx = taps(dst.x0, dst.x1, pass.sx, pass.kx, edge.map { ($0.x0, $0.x1 - 1) }, (area.x0, area.x1 - 1))
        let vy = taps(dst.y0, dst.y1, pass.sy, pass.ky, edge.map { ($0.y0, $0.y1 - 1) }, (area.y0, area.y1 - 1))
        let xLo = hx.filter { !$0.weights.isEmpty }.map(\.start).min() ?? area.x0
        let xHi = max(hx.map { $0.start + Int32($0.weights.count) }.max() ?? area.x0, xLo)
        let yLo = vy.filter { !$0.weights.isEmpty }.map(\.start).min() ?? area.y0
        let yHi = max(vy.map { $0.start + Int32($0.weights.count) }.max() ?? area.y0, yLo)
        return PassGeometry(dst: dst, area: area, hx: hx, vy: vy, xLo: xLo, xHi: xHi, yLo: yLo, yHi: yHi,
                            def: defaultPixel, defPremul: premultiplied(defaultPixel, alpha: alpha))
    }

    /// Samples one source read may hold (64 MB of `f32`); larger windows are read in row chunks.
    static let readBudget = 1 << 24
    /// Output rows per band.
    static let band = 64

    /// The CPU pass: bands of output rows in parallel groups; `write` receives each band (row
    /// rectangle and interleaved straight samples) in order, from the calling thread.
    static func runCPU(_ g: PassGeometry, _ s: some ResampleSource, alpha: Bool, budget: Int = readBudget,
                       write: (PixelRect, [Float]) -> Void) {
        let n = s.channels
        let dw = g.dst.width
        let vy = g.vy, xLo = g.xLo, xHi = g.xHi, def = g.defPremul, area = g.area
        let rowPixels = Int(xHi - xLo)
        // Flat horizontal tables: window start (relative to xLo), weight offset and count, outside.
        let (hTable, hWeights) = gpuTable(g.hx)
        let cores = max(ProcessInfo.processInfo.activeProcessorCount, 1)
        // Horizontal pass of one premultiplied source row (spanning `xLo ..< xHi`) into `dw` samples
        // (taps in order, then the default pixel's share).
        func horizontal(_ row: UnsafePointer<Float>, _ out: UnsafeMutablePointer<Float>, _ ht: UnsafePointer<GPUTap>,
                        _ hw: UnsafePointer<Float>, _ dp: UnsafePointer<Float>) {
            var ti = 0
            while ti < dw {
                let t = ht[ti]
                let o = out + ti * n
                var c = 0
                while c < n { o[c] = 0; c += 1 }
                let base = Int(t.start - xLo), cnt = Int(t.count), off = Int(t.offset)
                var k = 0
                while k < cnt {
                    let idx = base + k
                    if idx >= 0 && idx < rowPixels {
                        let sp = row + idx * n, wk = hw[off + k]
                        c = 0
                        while c < n { o[c] += sp[c] * wk; c += 1 }
                    }
                    k += 1
                }
                c = 0
                while c < n { o[c] += dp[c] * t.outside; c += 1 }
                ti += 1
            }
        }
        // A source row of nothing but the default pixel, after the horizontal pass.
        var defRow = [Float](repeating: 0, count: dw * n)
        do {
            var row = [Float](repeating: 0, count: max(rowPixels, 1) * n)
            for i in 0..<rowPixels { for c in 0..<n { row[i * n + c] = def[c] } }
            row.withUnsafeBufferPointer { r in
                defRow.withUnsafeMutableBufferPointer { d in
                    hTable.withUnsafeBufferPointer { ht in
                        hWeights.withUnsafeBufferPointer { hw in
                            def.withUnsafeBufferPointer { dp in horizontal(r.baseAddress!, d.baseAddress!, ht.baseAddress!, hw.baseAddress ?? dp.baseAddress!, dp.baseAddress!) }
                        }
                    }
                }
            }
        }
        let rowsPerRead = Int32(min(max(budget / max(max(rowPixels, 1) * n, dw * n), 1), Int(tileSize)))
        let bands: [(Int, Int)] = stride(from: 0, to: vy.count, by: band).map { ($0, min($0 + band, vy.count)) }
        let (vTable, vWeights) = gpuTable(vy)
        let run = { (b0: Int, b1: Int) -> [Float] in
            let bandTaps = vTable[b0..<b1]
            let yLo = bandTaps.filter { $0.count > 0 }.map(\.start).min() ?? area.y0
            let yHi = max(bandTaps.map { $0.start + $0.count }.max() ?? area.y0, yLo)
            let stride = dw * n
            let bn = b1 - b0
            var res = [Float](repeating: 0, count: bn * stride)
            var rows: [Float] = []
            var hrows: [Float] = []
            let innerParallel = bands.count < cores
            res.withUnsafeMutableBufferPointer { rbp in
                let rb = rbp.baseAddress!
                vTable.withUnsafeBufferPointer { vtp in
                    vWeights.withUnsafeBufferPointer { vwp in
                        defRow.withUnsafeBufferPointer { drp in
                            let vt = vtp.baseAddress! + b0, vw = vwp.baseAddress, dr = drp.baseAddress!
                            // Source rows stream through in bounded reads and go straight into the
                            // output rows that use them, in ascending row order (photocraft #713).
                            func add(_ y: Int32, _ row: UnsafePointer<Float>) {
                                var bi = 0
                                while bi < bn {
                                    let t = vt[bi]
                                    if y >= t.start && y - t.start < t.count {
                                        let w = vw![Int(t.offset) + Int(y - t.start)]
                                        let d = rb + bi * stride
                                        var j = 0
                                        while j < stride { d[j] += row[j] * w; j += 1 }
                                    }
                                    bi += 1
                                }
                            }
                            var y = yLo
                            while y < yHi {
                                let y1 = min((ResampleKit.floorDiv(y, tileSize) + 1) * tileSize, yHi)
                                if s.hasData(in: PixelRect(x0: xLo, y0: y, x1: xHi, y1: y1)) {
                                    var c0 = y
                                    while c0 < y1 {
                                        let c1 = min(c0 + rowsPerRead, y1)
                                        let read = PixelRect(x0: xLo, y0: c0, x1: xHi, y1: c1)
                                        s.read(read, into: &rows)
                                        premultiply(&rows, n, alpha)
                                        let count = Int(c1 - c0)
                                        if hrows.count != count * stride { hrows = [Float](repeating: 0, count: count * stride) }
                                        let rw = read.width * n
                                        if rw > 0 {
                                            rows.withUnsafeBufferPointer { rp in
                                                hrows.withUnsafeMutableBufferPointer { hp in
                                                    hTable.withUnsafeBufferPointer { ht in
                                                        hWeights.withUnsafeBufferPointer { hw in
                                                            def.withUnsafeBufferPointer { dp in
                                                                let r0 = UnsafeSendable(rp.baseAddress!), h0 = UnsafeSendable(hp.baseAddress!)
                                                                let t0 = UnsafeSendable(ht.baseAddress!), w0 = UnsafeSendable(hw.baseAddress ?? dp.baseAddress!)
                                                                let d0 = UnsafeSendable(dp.baseAddress!)
                                                                let one = { (r: Int) in horizontal(r0.value + r * rw, h0.value + r * stride, t0.value, w0.value, d0.value) }
                                                                if innerParallel && count > 1 {
                                                                    parallelChunks(count, minChunk: max(1, 4096 / max(dw, 1))) { range in for r in range { one(r) } }
                                                                } else {
                                                                    for r in 0..<count { one(r) }
                                                                }
                                                            }
                                                        }
                                                    }
                                                }
                                            }
                                            hrows.withUnsafeBufferPointer { hp in
                                                for r in 0..<count { add(c0 + Int32(r), hp.baseAddress! + r * stride) }
                                            }
                                        }
                                        c0 = c1
                                    }
                                } else {
                                    // Nothing stored in this tile row: every row in it is the default
                                    // row, so each output row takes it once, with the summed weight of
                                    // those rows.
                                    var bi = 0
                                    while bi < bn {
                                        let t = vt[bi]
                                        let len = Int(t.count)
                                        let lo = min(Int(max(y - t.start, 0)), len), hi = min(Int(max(y1 - t.start, 0)), len)
                                        var w: Float = 0
                                        var k = lo
                                        while k < hi { w += vw![Int(t.offset) + k]; k += 1 }
                                        if w != 0 {
                                            let d = rb + bi * stride
                                            var j = 0
                                            while j < stride { d[j] += dr[j] * w; j += 1 }
                                        }
                                        bi += 1
                                    }
                                }
                                y = y1
                            }
                            var bi = 0
                            while bi < bn {
                                let o = vt[bi].outside
                                let d = rb + bi * stride
                                var j = 0
                                while j < stride { d[j] += dr[j] * o; j += 1 }
                                bi += 1
                            }
                        }
                    }
                }
                if alpha {
                    var p = n - 1
                    while p < rbp.count { rb[p] = min(max(rb[p], 0), 1); p += n }
                }
            }
            unpremultiply(&res, n, alpha)
            return res
        }
        // Bands go into the output a group at a time, so the rows held at once are bounded by the
        // group, not by the whole destination (photocraft #1544).
        let group = max(ProcessInfo.processInfo.activeProcessorCount, 1) * 2
        var gi = 0
        while gi < bands.count {
            let chunk = Array(bands[gi..<min(gi + group, bands.count)])
            var parts = [[Float]](repeating: [], count: chunk.count)
            parts.withUnsafeMutableBufferPointer { pb in
                let p = UnsafeSendable(pb)
                parallelFor(chunk.count) { i in p.value[i] = run(chunk[i].0, chunk[i].1) }
            }
            for (i, (b0, b1)) in chunk.enumerated() {
                write(PixelRect(x0: g.dst.x0, y0: g.dst.y0 + Int32(b0), x1: g.dst.x1, y1: g.dst.y0 + Int32(b1)), parts[i])
            }
            gi += group
        }
    }

    /// Tight bounds of the pixels of `img` whose stored bits differ from `def` (photocraft
    /// `Surface::content_bounds`, which compares encoded pixels).
    static func contentBounds(_ img: FloatImage, _ def: [Float]) -> PixelRect {
        let n = img.channels, w = img.width
        if img.rect.isEmpty || n == 0 { return .empty }
        let defBits = def.map(\.bitPattern)
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        img.data.withUnsafeBufferPointer { d in
            for y in 0..<img.height {
                var first = -1, last = -1
                for x in 0..<w {
                    let b = (y * w + x) * n
                    var differs = false
                    for c in 0..<n where d[b + c].bitPattern != defBits[c] { differs = true; break }
                    if differs { if first < 0 { first = x }; last = x }
                }
                if first >= 0 {
                    minX = min(minX, first); maxX = max(maxX, last); minY = min(minY, y); maxY = y
                }
            }
        }
        if maxX < 0 { return .empty }
        return PixelRect(x0: img.rect.x0 + Int32(minX), y0: img.rect.y0 + Int32(minY), x1: img.rect.x0 + Int32(maxX) + 1, y1: img.rect.y0 + Int32(maxY) + 1)
    }

    /// Tight bounds of the pixels of `s` that differ from its default pixel (photocraft
    /// `Surface::content_bounds`: tiles scanned from the outside of the tile grid inwards, a tile
    /// inside the bounds found so far skipped; rows compared with `memcmp`).
    static func contentBounds(_ s: Surface) -> PixelRect {
        let coords = s.tileCoords
        if coords.isEmpty { return .empty }
        let bpp = s.format.bytesPerPixel, ts = Int(tileSize)
        var gx0 = Int32.max, gy0 = Int32.max, gx1 = Int32.min, gy1 = Int32.min
        for c in coords { gx0 = min(gx0, c.tx); gy0 = min(gy0, c.ty); gx1 = max(gx1, c.tx); gy1 = max(gy1, c.ty) }
        let order = coords.sorted { a, b in
            let da = min(a.tx - gx0, gx1 - a.tx, a.ty - gy0, gy1 - a.ty), db = min(b.tx - gx0, gx1 - b.tx, b.ty - gy0, gy1 - b.ty)
            return da < db
        }
        let dp = Surface(format: s.format, defaultPixel: s.defaultPixelValue)
        var defRow = [UInt8](repeating: 0, count: ts * bpp)
        let defPx = dp.readInterleaved(PixelRect(x0: 0, y0: 0, x1: 1, y1: 1))
        for i in 0..<ts { for k in 0..<bpp { defRow[i * bpp + k] = defPx[k] } }
        var out = PixelRect.empty
        for c in order {
            let origin = c.rect
            if !out.isEmpty && out.contains(origin) { continue }
            guard let t = s.tile(c) else { continue }
            var x0 = Int.max, y0 = Int.max, x1 = -1, y1 = -1
            t.bytes.withUnsafeBytes { p in
                defRow.withUnsafeBytes { d in
                    let pb = p.baseAddress!, db = d.baseAddress!
                    for y in 0..<ts {
                        let row = pb + y * ts * bpp
                        if memcmp(row, db, ts * bpp) == 0 { continue }
                        var first = 0
                        while first < ts && memcmp(row + first * bpp, db, bpp) == 0 { first += 1 }
                        var last = ts - 1
                        while last > first && memcmp(row + last * bpp, db, bpp) == 0 { last -= 1 }
                        x0 = min(x0, first); x1 = max(x1, last)
                        if y0 == Int.max { y0 = y }
                        y1 = y
                    }
                }
            }
            if x1 >= 0 {
                out = out.union(PixelRect(x0: origin.x0 + Int32(x0), y0: origin.y0 + Int32(y0), x1: origin.x0 + Int32(x1) + 1, y1: origin.y0 + Int32(y1) + 1))
            }
        }
        return out
    }

    /// The default pixel of `s` encoded, repeated over one tile row.
    static func defaultRowBytes(_ s: Surface) -> [UInt8] {
        let bpp = s.format.bytesPerPixel, ts = Int(tileSize)
        let px = encodePixel(s.format, s.defaultPixelValue)
        var row = [UInt8](repeating: 0, count: ts * bpp)
        for i in 0..<ts { for k in 0..<bpp { row[i * bpp + k] = px[k] } }
        return row
    }

    /// Drops the tiles that equal the default pixel everywhere (`Surface.prune`, comparing rows
    /// with `memcmp`).
    static func prune(_ s: inout Surface) {
        let bpp = s.format.bytesPerPixel, ts = Int(tileSize)
        let defRow = defaultRowBytes(s)
        var empty: [TileCoord] = []
        for c in s.tileCoords {
            guard let t = s.tile(c) else { continue }
            let uniform = t.bytes.withUnsafeBytes { p in
                defRow.withUnsafeBytes { d in
                    (0..<ts).allSatisfy { memcmp(p.baseAddress! + $0 * ts * bpp, d.baseAddress!, ts * bpp) == 0 }
                }
            }
            if uniform { empty.append(c) }
        }
        for c in empty { _ = s.takeTiles(c.rect) }
    }

    /// `Surface.writeRegion` (integer samples clamped and rounded half up, floats stored as they
    /// are) through one encoding pass and `writeInterleaved`.
    static func write(_ s: inout Surface, _ r: PixelRect, _ data: [Float]) {
        if r.isEmpty { return }
        let fmt = s.format
        let count = r.area * fmt.channels
        precondition(data.count >= count, "write: data too short")
        var bytes = [UInt8](repeating: 0, count: count * fmt.sample.bytes)
        bytes.withUnsafeMutableBytes { b in
            data.withUnsafeBufferPointer { d in
                switch fmt.sample {
                case .u8:
                    let o = b.bindMemory(to: UInt8.self)
                    for i in 0..<count { o[i] = UInt8(min(max(d[i], 0), 1) * 255 + 0.5) }
                case .u16:
                    let o = b.bindMemory(to: UInt16.self)
                    for i in 0..<count { o[i] = UInt16(min(max(d[i], 0), 1) * 65535 + 0.5) }
                case .f32:
                    b.copyMemory(from: UnsafeRawBufferPointer(rebasing: UnsafeRawBufferPointer(d)[0..<(count * 4)]))
                }
            }
        }
        s.writeInterleaved(r, bytes)
    }

    /// `img` over `r`, the default pixel outside it.
    static func padded(_ img: FloatImage, _ r: PixelRect, _ def: [Float]) -> FloatImage {
        if img.rect == r { return img }
        var buf: [Float] = []
        ImageSource(image: img, defaultPixel: def).read(r, into: &buf)
        return FloatImage(rect: r, channels: img.channels, data: buf)
    }
}

// MARK: - Metal pass

extension ResampleKit {
    /// MSL `pca_rs_tap`.
    struct GPUTap: BitwiseCopyable {
        var start: Int32
        var offset: Int32
        var count: Int32
        var outside: Float
    }

    /// MSL `pca_rs_pass_params`.
    struct PassParams: BitwiseCopyable {
        var def: SIMD4<Float>
        var tmpOrigin: SIMD2<Int32>
        var tmpSize: SIMD2<Int32>
        var xLo: Int32
        var pad0: Int32 = 0
        var pad1: Int32 = 0
        var pad2: Int32 = 0
    }

    static func gpuTable(_ taps: [Taps]) -> ([GPUTap], [Float]) {
        var table: [GPUTap] = []
        table.reserveCapacity(taps.count)
        var w: [Float] = []
        for t in taps {
            table.append(GPUTap(start: t.start, offset: Int32(w.count), count: Int32(t.weights.count), outside: t.outside))
            w.append(contentsOf: t.weights)
        }
        return (table, w)
    }

    /// One pass as a filter over `g.dst` (the source is the pass input; outside it, the default
    /// pixel). CPU: `runCPU`; Metal: a horizontal kernel into an intermediate covering the output
    /// columns and the rows the vertical taps read, then the vertical kernel.
    struct PassFilter: Filter {
        var geometry: PassGeometry
        var label: String { "Image Size" }
        func halo(bounds: PixelRect) -> Halo { .bounds }

        func cpu(_ src: FloatImage, out: PixelRect, ctx: FilterContext) -> FloatImage {
            var res = FloatImage(rect: out, channels: src.channels)
            let g = geometry
            let n = src.channels
            ResampleKit.runCPU(g, ImageSource(image: src, defaultPixel: g.def), alpha: ctx.alpha) { r, data in
                let inner = r.intersect(out)
                if inner.isEmpty { return }
                for y in inner.y0..<inner.y1 {
                    let si = (Int(y - r.y0) * r.width + Int(inner.x0 - r.x0)) * n
                    let di = res.index(x: inner.x0, y: y)
                    for i in 0..<(inner.width * n) { res.data[di + i] = data[si + i] }
                }
            }
            return res
        }

        func encodeGPU(_ pass: GPUPass) throws {
            let g = geometry
            precondition(pass.out == g.dst, "Image Size pass: output must be the pass destination")
            // The default pixel in this plane's layout.
            var def = SIMD4<Float>(repeating: 0)
            for (k, c) in pass.planeChannels.enumerated() where c < g.def.count { def[k] = g.def[c] }
            if pass.ctx.alpha, let a = g.def.last { def[3] = a }
            let tmpRect = PixelRect(x0: g.dst.x0, y0: g.yLo, x1: g.dst.x1, y1: max(g.yHi, g.yLo + 1))
            let tmp = try pass.texture(tmpRect)
            let (ht, hw) = gpuTable(g.hx), (vt, vw) = gpuTable(g.vy)
            let htb = try pass.buffer(ht), hwb = try pass.buffer(hw), vtb = try pass.buffer(vt), vwb = try pass.buffer(vw)
            let p = PassParams(def: def, tmpOrigin: SIMD2(tmpRect.x0, tmpRect.y0),
                               tmpSize: SIMD2(Int32(tmpRect.width), Int32(tmpRect.height)), xLo: g.xLo)
            if g.yHi > g.yLo {
                try pass.dispatch("pca_rs_resample_h", params: p, textures: [pass.src, tmp], buffers: [htb, hwb],
                                  width: tmpRect.width, height: Int(g.yHi - g.yLo))
            }
            try pass.dispatchOut("pca_rs_resample_v", params: p, textures: [tmp, pass.dst], buffers: [htb, hwb, vtb, vwb])
        }
    }
}

// MARK: - Drivers

extension Resample {
    /// Resizes a surface by `(sx, sy)` about the document origin (photocraft `resize_surface`).
    /// The surface's default pixel is kept (masks keep their "reveal all" background). `.cpu`
    /// streams the source in bounded reads (any size, sparse surfaces cheap); `.gpu`/`.auto` run the
    /// Metal passes when the content fits one GPU pass, else (or on any GPU failure) the CPU.
    public static func resizeSurface(_ s: Surface, sx: Double, sy: Double, filter: Resample = .bicubic, on backend: Backend = .auto) -> Surface {
        ResampleKit.resizeSurface(s, sx: sx, sy: sy, filter: filter, canvas: nil, budget: ResampleKit.readBudget, backend: backend)
    }

    /// `resizeSurface` for a layer, mask or channel of a document whose canvas is `canvas` (Image
    /// Size; photocraft `resize_surface_in_canvas`): at the canvas edges the pixels repeat outwards,
    /// so content that reaches an edge keeps it (an opaque layer stays opaque to the border) instead
    /// of fading into the default pixel. Pixels beyond the canvas count as the surface's own, and
    /// inside the canvas nothing changes.
    public static func resizeSurfaceInCanvas(_ s: Surface, sx: Double, sy: Double, filter: Resample = .bicubic, canvas: PixelRect,
                                             on backend: Backend = .auto) -> Surface {
        ResampleKit.resizeSurface(s, sx: sx, sy: sy, filter: filter, canvas: canvas, budget: ResampleKit.readBudget, backend: backend)
    }

    /// Moves a surface by whole pixels (default pixel kept) — photocraft `translate_surface`.
    public static func translateSurface(_ s: Surface, dx: Int32, dy: Int32) -> Surface {
        s.translated(dx: dx, dy: dy, content: ResampleKit.contentBounds(s))
    }

    /// Keeps only the pixels inside `keep` (others become the default pixel) — photocraft
    /// `crop_surface`.
    public static func cropSurface(_ s: Surface, keep: PixelRect) -> Surface {
        var out = Surface(format: s.format, defaultPixel: s.defaultPixelValue)
        let r = ResampleKit.contentBounds(s).intersect(keep)
        if !r.isEmpty { out.writeInterleaved(r, s.readInterleaved(r)) }
        return out
    }

    /// Resizes a dense image by `(sx, sy)` about the document origin: exactly the pixels
    /// `resizeSurface` gives over `scaledRect(img.rect)` for a surface holding `img` (outside it,
    /// `defaultPixel`, 0 by default). `canvas` repeats the canvas edge (`resizeSurfaceInCanvas`).
    /// Between two passes the image is stored as `storage` (integer types clip and round, as
    /// Photoshop's stored intermediate does; the default `.f32` keeps HDR and signed values); the
    /// returned samples are not quantised. `context` says whether the last channel is alpha
    /// (default: inferred from the channel count).
    public static func resize(_ img: FloatImage, sx: Double, sy: Double, filter: Resample = .bicubic, canvas: PixelRect? = nil,
                              context: FilterContext? = nil, defaultPixel: [Float]? = nil, storage: SampleType = .f32,
                              on backend: Backend = .auto) throws -> FloatImage {
        let ctx = context ?? FilterContext.inferred(channels: img.channels, bounds: img.rect)
        let def = (defaultPixel ?? [Float](repeating: 0, count: img.channels)).map { ResampleKit.quantize($0, storage) }
        precondition(def.count == img.channels, "defaultPixel needs one value per channel")
        var cur = try ResampleKit.resizePasses(img, sx: sx, sy: sy, filter: filter, canvas: canvas, ctx: ctx, def: def,
                                               storage: storage, backend: backend)
        if filter == .preserveDetails && (sx > 1 || sy > 1) {
            cur = try ResampleKit.preserveDetailsSharpen(cur, sx: sx, sy: sy, ctx: ctx, def: def, storage: storage, backend: backend)
        }
        return ResampleKit.padded(cur, scaledRect(img.rect, sx: sx, sy: sy), def)
    }

    /// `resize` to a pixel size: the scale is `size / img size` per axis (as Image Size computes
    /// it) and the result covers exactly `size` pixels from the scaled origin.
    public static func resize(_ img: FloatImage, to size: PixelSize, filter: Resample = .bicubic, canvas: PixelRect? = nil,
                              context: FilterContext? = nil, defaultPixel: [Float]? = nil, storage: SampleType = .f32,
                              on backend: Backend = .auto) throws -> FloatImage {
        precondition(img.width > 0 && img.height > 0, "resize(to:) needs a non-empty image")
        let sx = Double(size.width) / Double(img.width), sy = Double(size.height) / Double(img.height)
        let r = try resize(img, sx: sx, sy: sy, filter: filter, canvas: canvas, context: context, defaultPixel: defaultPixel,
                           storage: storage, on: backend)
        let def = defaultPixel ?? [Float](repeating: 0, count: img.channels)
        return ResampleKit.padded(r, PixelRect(x: Int(r.rect.x0), y: Int(r.rect.y0), width: size.width, height: size.height), def)
    }
}

extension ResampleKit {
    /// Whether a pass fits the Metal path (texture limits).
    static func gpuFits(_ g: PassGeometry, src: PixelRect) -> Bool {
        let m = FilterEngine.maxGPUSize
        return max(src.width, src.height, g.dst.width, g.dst.height) <= m && Int(g.yHi - g.yLo) <= m
    }

    /// The passes of `filter` over a dense image (no Preserve Details sharpening): each pass reads
    /// the previous result's content (tight bounds against the default pixel), stored as `storage`
    /// between passes. Returns the last pass's output over its own rectangle.
    static func resizePasses(_ img: FloatImage, sx: Double, sy: Double, filter: Resample, canvas canvas0: PixelRect?, ctx: FilterContext,
                             def: [Float], storage: SampleType, backend: Backend) throws -> FloatImage {
        var cur = img
        var canvas = canvas0
        let passes = plan(filter, sx, sy)
        let keepStored = filter == .preserveDetails && (sx > 1 || sy > 1)
        for (i, p) in passes.enumerated() {
            let content = contentBounds(cur, def)
            if let g = prepare(content: content, defaultPixel: def, alpha: ctx.alpha, pass: p, canvas: canvas) {
                let useGPU: Bool
                switch backend {
                case .cpu: useGPU = false
                case .gpu:
                    guard gpuFits(g, src: cur.rect) else { throw FilterError.gpuUnsupported("Image Size pass larger than \(FilterEngine.maxGPUSize) px") }
                    useGPU = true
                case .auto: useGPU = AlgoGPU.isAvailable && gpuFits(g, src: cur.rect)
                }
                var c = ctx
                c.bounds = g.dst
                cur = try FilterEngine.apply(PassFilter(geometry: g), to: cur, output: g.dst, context: c, on: useGPU ? .gpu : .cpu)
            } else {
                cur = FloatImage(rect: .empty, channels: img.channels)
            }
            canvas = canvas.map { Resample.scaledRect($0, sx: p.sx, sy: p.sy) }
            if (i + 1 < passes.count || keepStored) && storage != .f32 {
                cur.data.withUnsafeMutableBufferPointer { d in
                    for j in 0..<d.count { d[j] = quantize(d[j], storage) }
                }
            }
        }
        return cur
    }

    /// Preserve Details' enlargement sharpening: Unsharp Mask 30 %, radius 0.6 · max scale,
    /// threshold 0 over the result's content grown by the blur's halo (photocraft
    /// `resize_with_budget`), on the stored result.
    static func preserveDetailsSharpen(_ img: FloatImage, sx: Double, sy: Double, ctx: FilterContext, def: [Float], storage: SampleType,
                                       backend: Backend) throws -> FloatImage {
        let f = Unsharp(amount: 30, radius: Float(0.6) * Float(max(sx, sy)), threshold: 0)
        let dst = contentBounds(img, def)
        if dst.isEmpty { return img }
        guard case .radius(let h) = f.halo(bounds: dst) else { return img }
        let area = dst.outset(by: h)
        let src = padded(img, area.outset(by: h), def)
        var c = ctx
        c.bounds = dst
        let sharpened = try FilterEngine.apply(f, to: src, output: area, context: c, on: backend)
        // The result keeps the sharpened area plus the unsharpened rest of the image.
        let rect = img.rect.union(area)
        var out = padded(img, rect, def)
        let n = img.channels
        for y in area.y0..<area.y1 {
            let si = sharpened.index(x: area.x0, y: y), di = out.index(x: area.x0, y: y)
            for i in 0..<(area.width * n) { out.data[di + i] = sharpened.data[si + i] }
        }
        return out
    }

    /// The surface-level driver (photocraft `resize_with_budget`).
    static func resizeSurface(_ s: Surface, sx: Double, sy: Double, filter: Resample, canvas canvas0: PixelRect?, budget: Int,
                              backend: Backend) -> Surface {
        if backend != .cpu, AlgoGPU.isAvailable, let out = try? resizeSurfaceGPU(s, sx: sx, sy: sy, filter: filter, canvas: canvas0, backend: backend) {
            return out
        }
        var cur: Surface? = nil
        var canvas = canvas0
        for p in plan(filter, sx, sy) {
            let next = resizePassSurface(cur ?? s, p, canvas: canvas, budget: budget)
            canvas = canvas.map { Resample.scaledRect($0, sx: p.sx, sy: p.sy) }
            cur = next
        }
        var out = cur ?? s
        if filter == .preserveDetails && (sx > 1 || sy > 1) {
            sharpenSurface(&out, sx: sx, sy: sy, backend: .cpu)
        }
        prune(&out)
        return out
    }

    /// One CPU pass of a surface into a new surface with the same format and default pixel
    /// (photocraft `resize_pass`).
    static func resizePassSurface(_ s: Surface, _ pass: Pass, canvas: PixelRect?, budget: Int) -> Surface {
        var out = Surface(format: s.format, defaultPixel: s.defaultPixelValue)
        let src = SurfaceSource(s)
        guard let g = prepare(content: contentBounds(s), defaultPixel: src.defaultPixel, alpha: s.format.alpha, pass: pass, canvas: canvas) else {
            return out
        }
        runCPU(g, src, alpha: s.format.alpha, budget: budget) { r, data in write(&out, r, data) }
        return out
    }

    /// Preserve Details' sharpening on a surface (photocraft `crate::apply` of Unsharp Mask over
    /// the content grown by its halo).
    static func sharpenSurface(_ out: inout Surface, sx: Double, sy: Double, backend: Backend) {
        let dst = contentBounds(out)
        let f = Unsharp(amount: 30, radius: Float(0.6) * Float(max(sx, sy)), threshold: 0)
        let area = FilterEngine.outputArea(f, content: dst, bounds: dst)
        if area.isEmpty { return }
        if (try? FilterEngine.apply(f, to: &out, area: area, bounds: dst, on: backend)) == nil {
            try? FilterEngine.apply(f, to: &out, area: area, bounds: dst, on: .cpu)
        }
    }

    /// `resizeSurface` through the dense Metal passes, when the content is small enough to hold.
    static func resizeSurfaceGPU(_ s: Surface, sx: Double, sy: Double, filter: Resample, canvas: PixelRect?, backend: Backend) throws -> Surface? {
        let content = contentBounds(s)
        let m = FilterEngine.maxGPUSize
        let dst = Resample.scaledRect(content, sx: sx, sy: sy)
        if content.width > m || content.height > m || dst.width > m || dst.height > m || content.area > 1 << 26 || dst.area > 1 << 26 {
            return nil
        }
        let ctx = FilterContext(bounds: content, format: s.format)
        let def = s.defaultPixelValue
        let img = FloatImage(surface: s, rect: content)
        let res = try resizePasses(img, sx: sx, sy: sy, filter: filter, canvas: canvas, ctx: ctx, def: def, storage: s.format.sample,
                                   backend: backend == .gpu ? .gpu : .auto)
        var out = Surface(format: s.format, defaultPixel: def)
        write(&out, res.rect, res.data)
        if filter == .preserveDetails && (sx > 1 || sy > 1) {
            sharpenSurface(&out, sx: sx, sy: sy, backend: backend)
        }
        prune(&out)
        return out
    }
}
