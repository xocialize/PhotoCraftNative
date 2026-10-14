// New (no photocraft counterpart: photocraft's `proxy.rs` downsamples whole documents by nearest
// neighbour): box reductions of document tiles, the reduced sources a level of detail is composited
// from (AB-T-0256).
//
// A source tile (256², any `PixelFormat`) reduces at level L to a block of (256 >> L)² pixels of the
// same format. Each block pixel is the mean of its 2^L × 2^L source pixels: in formats with alpha the
// colour channels are weighted by alpha (straight colour from premultiplied sums, as
// `DocumentCompositor.renderReduced` averages a composite) and a fully transparent block is zero;
// without alpha every channel is a plain mean. Integer samples round half up, floats are stored as
// they come. A tile's generation names its bytes wherever the tile sits (Surface.swift), so a block
// is cached by (generation, level, format) across surfaces and documents. Missing tiles reduce to the
// surface's default pixel (the mean of one value is that value).

import Foundation
import PCFoundation

enum TileReduction {
    /// Pixels a side of a tile's block at `level`.
    @inline(__always) static func blockSide(_ level: Int) -> Int { Int(tileSize) >> level }

    /// `reduce`, or with `sampled` `sample`.
    @inline(__always)
    static func block(_ src: UnsafeRawPointer, format: PixelFormat, level: Int, sampled: Bool, into dst: UnsafeMutableRawPointer, rowBytes: Int) {
        if sampled { sample(src, format: format, level: level, into: dst, rowBytes: rowBytes) } else { reduce(src, format: format, level: level, into: dst, rowBytes: rowBytes) }
    }

    /// The block of a sampled preview: each pixel the source pixel at its block's centre (rounded
    /// toward the block's corner), copied. Reads one pixel in 4^level.
    static func sample(_ src: UnsafeRawPointer, format: PixelFormat, level: Int, into dst: UnsafeMutableRawPointer, rowBytes: Int) {
        let ts = Int(tileSize), f = 1 << level, o = ts >> level, bpp = format.bytesPerPixel, c = f / 2
        for oy in 0..<o {
            let row = src + (oy * f + c) * ts * bpp, out = dst + oy * rowBytes
            if bpp == 4 {
                for ox in 0..<o { (out + ox * 4).storeBytes(of: (row + (ox * f + c) * 4).loadUnaligned(as: UInt32.self), as: UInt32.self) }
            } else {
                for ox in 0..<o { (out + ox * bpp).copyMemory(from: row + (ox * f + c) * bpp, byteCount: bpp) }
            }
        }
    }

    /// Writes the reduction of one tile (`src`: tileSize² pixels of `format`) at `level` (1 … 8) into
    /// `dst`: `blockSide(level)` rows of `rowBytes` bytes, pixels packed in `format`.
    static func reduce(_ src: UnsafeRawPointer, format: PixelFormat, level: Int, into dst: UnsafeMutableRawPointer, rowBytes: Int) {
        let ch = format.channels
        switch format.sample {
        case .u8:
            if ch == 4 && format.alpha {
                rgba8(src, level: level, dst: dst, rowBytes: rowBytes)
            } else if ch == 1 {
                gray8(src, level: level, dst: dst, rowBytes: rowBytes)
            } else {
                integer(src, UInt8.self, ch: ch, alpha: format.alpha, level: level, dst: dst, rowBytes: rowBytes)
            }
        case .u16:
            integer(src, UInt16.self, ch: ch, alpha: format.alpha, level: level, dst: dst, rowBytes: rowBytes)
        case .f32:
            float(src.assumingMemoryBound(to: Float.self), ch: ch, alpha: format.alpha, level: level, dst: dst, rowBytes: rowBytes)
        }
    }

    /// RGBA8, the common case: four pixels at a time, premultiplied in 16 bits (v·a ≤ 255²), summed
    /// down the block's rows and across its columns in 32 bits (Σ v·a ≤ 65536 · 255² < 2³² at level 8).
    private static func rgba8(_ src: UnsafeRawPointer, level: Int, dst: UnsafeMutableRawPointer, rowBytes: Int) {
        let ts = Int(tileSize), f = 1 << level, o = ts >> level
        let n = UInt32(f * f), half = n / 2
        // Per output column: Σ r·a, Σ g·a, Σ b·a, Σ a.
        var acc = [SIMD4<UInt32>](repeating: .zero, count: o)
        acc.withUnsafeMutableBufferPointer { ab in
            let A = ab.baseAddress!
            for oy in 0..<o {
                A.update(repeating: .zero, count: o)
                let rows = src + oy * f * ts * 4
                var x = 0
                while x < ts {
                    // Four pixels (16 bytes), down the block's f rows.
                    var sum = SIMD16<UInt32>.zero
                    for k in 0..<f {
                        let v = SIMD16<UInt16>(truncatingIfNeeded: (rows + (k * ts + x) * 4).loadUnaligned(as: SIMD16<UInt8>.self))
                        let w = SIMD16<UInt16>(v[3], v[3], v[3], 1, v[7], v[7], v[7], 1, v[11], v[11], v[11], 1, v[15], v[15], v[15], 1)
                        sum &+= SIMD16<UInt32>(truncatingIfNeeded: v &* w)
                    }
                    let p0 = sum.lowHalf.lowHalf, p1 = sum.lowHalf.highHalf, p2 = sum.highHalf.lowHalf, p3 = sum.highHalf.highHalf
                    if f == 1 {
                        A[x] &+= p0; A[x + 1] &+= p1; A[x + 2] &+= p2; A[x + 3] &+= p3
                    } else if f == 2 {
                        A[x >> 1] &+= p0 &+ p1; A[(x >> 1) + 1] &+= p2 &+ p3
                    } else {
                        A[x >> level] &+= (p0 &+ p1) &+ (p2 &+ p3)
                    }
                    x += 4
                }
                let out = (dst + oy * rowBytes).assumingMemoryBound(to: UInt8.self)
                for ox in 0..<o {
                    let q = A[ox], w = out + ox * 4
                    let sa = q.w
                    if sa == 0 {
                        w[0] = 0; w[1] = 0; w[2] = 0; w[3] = 0
                    } else {
                        let h = sa / 2
                        w[0] = UInt8(truncatingIfNeeded: (q.x &+ h) / sa)
                        w[1] = UInt8(truncatingIfNeeded: (q.y &+ h) / sa)
                        w[2] = UInt8(truncatingIfNeeded: (q.z &+ h) / sa)
                        w[3] = UInt8(truncatingIfNeeded: (sa &+ half) / n)
                    }
                }
            }
        }
    }

    /// One 8-bit channel without alpha (masks): sixteen pixels at a time, summed down the block's
    /// rows in 16 bits (≤ 256 · 255), then across its columns.
    private static func gray8(_ src: UnsafeRawPointer, level: Int, dst: UnsafeMutableRawPointer, rowBytes: Int) {
        let ts = Int(tileSize), f = 1 << level, o = ts >> level
        let n = UInt32(f * f), half = n / 2
        var acc = [UInt32](repeating: 0, count: o)
        acc.withUnsafeMutableBufferPointer { ab in
            let A = ab.baseAddress!
            for oy in 0..<o {
                A.update(repeating: 0, count: o)
                let rows = src + oy * f * ts
                var x = 0
                while x < ts {
                    var sum = SIMD16<UInt16>.zero
                    for k in 0..<f { sum &+= SIMD16<UInt16>(truncatingIfNeeded: (rows + k * ts + x).loadUnaligned(as: SIMD16<UInt8>.self)) }
                    switch level {
                    case 1:
                        let s = SIMD8<UInt32>(truncatingIfNeeded: sum.evenHalf &+ sum.oddHalf)
                        for k in 0..<8 { A[(x >> 1) + k] &+= s[k] }
                    case 2:
                        let s1 = sum.evenHalf &+ sum.oddHalf
                        let s = SIMD4<UInt32>(truncatingIfNeeded: s1.evenHalf &+ s1.oddHalf)
                        for k in 0..<4 { A[(x >> 2) + k] &+= s[k] }
                    case 3:
                        let s1 = SIMD8<UInt32>(truncatingIfNeeded: sum.evenHalf &+ sum.oddHalf)
                        let s2 = s1.evenHalf &+ s1.oddHalf
                        A[x >> 3] &+= s2[0] &+ s2[1]; A[(x >> 3) + 1] &+= s2[2] &+ s2[3]
                    default:
                        A[x >> level] &+= SIMD16<UInt32>(truncatingIfNeeded: sum).wrappedSum()
                    }
                    x += 16
                }
                let out = (dst + oy * rowBytes).assumingMemoryBound(to: UInt8.self)
                for ox in 0..<o { out[ox] = UInt8(truncatingIfNeeded: (A[ox] &+ half) / n) }
            }
        }
    }

    /// Any 8- or 16-bit format, in 64-bit sums.
    private static func integer<T: FixedWidthInteger & UnsignedInteger>(_ src0: UnsafeRawPointer, _: T.Type, ch: Int, alpha: Bool, level: Int,
                                                                       dst: UnsafeMutableRawPointer, rowBytes: Int) {
        let src = src0.assumingMemoryBound(to: T.self)
        let ts = Int(tileSize), f = 1 << level, o = ts >> level
        let n = UInt64(f * f)
        let cc = alpha ? ch - 1 : ch
        var acc = [UInt64](repeating: 0, count: o * ch)
        acc.withUnsafeMutableBufferPointer { ab in
            let A = ab.baseAddress!
            for oy in 0..<o {
                A.update(repeating: 0, count: o * ch)
                for sy in (oy * f)..<(oy * f + f) {
                    let row = src + sy * ts * ch
                    for sx in 0..<ts {
                        let p = row + sx * ch, q = A + (sx >> level) * ch
                        if alpha {
                            let a = UInt64(p[cc])
                            for c in 0..<cc { q[c] &+= UInt64(p[c]) &* a }
                            q[cc] &+= a
                        } else {
                            for c in 0..<ch { q[c] &+= UInt64(p[c]) }
                        }
                    }
                }
                let out = (dst + oy * rowBytes).assumingMemoryBound(to: T.self)
                for ox in 0..<o {
                    let q = A + ox * ch, w = out + ox * ch
                    if alpha {
                        let sa = q[cc]
                        for c in 0..<cc { w[c] = sa == 0 ? 0 : T(truncatingIfNeeded: (q[c] &+ sa / 2) / sa) }
                        w[cc] = T(truncatingIfNeeded: (sa &+ n / 2) / n)
                    } else {
                        for c in 0..<ch { w[c] = T(truncatingIfNeeded: (q[c] &+ n / 2) / n) }
                    }
                }
            }
        }
    }

    /// 32-bit float formats, in double sums (alpha weights below zero count as zero).
    private static func float(_ src: UnsafePointer<Float>, ch: Int, alpha: Bool, level: Int, dst: UnsafeMutableRawPointer, rowBytes: Int) {
        let ts = Int(tileSize), f = 1 << level, o = ts >> level
        let n = Double(f * f)
        let cc = alpha ? ch - 1 : ch
        // Per column: the channel sums, then (with alpha) the weight sum.
        let stride = alpha ? ch + 1 : ch
        var acc = [Double](repeating: 0, count: o * stride)
        acc.withUnsafeMutableBufferPointer { ab in
            let A = ab.baseAddress!
            for oy in 0..<o {
                A.update(repeating: 0, count: o * stride)
                for sy in (oy * f)..<(oy * f + f) {
                    let row = src + sy * ts * ch
                    for sx in 0..<ts {
                        let p = row + sx * ch, q = A + (sx >> level) * stride
                        if alpha {
                            let a = Double(max(p[cc], 0))
                            for c in 0..<cc { q[c] += Double(p[c]) * a }
                            q[cc] += Double(p[cc])
                            q[ch] += a
                        } else {
                            for c in 0..<ch { q[c] += Double(p[c]) }
                        }
                    }
                }
                let out = (dst + oy * rowBytes).assumingMemoryBound(to: Float.self)
                for ox in 0..<o {
                    let q = A + ox * stride, w = out + ox * ch
                    if alpha {
                        let wsum = q[ch]
                        for c in 0..<cc { w[c] = wsum > 0 ? Float(q[c] / wsum) : 0 }
                        w[cc] = Float(q[cc] / n)
                    } else {
                        for c in 0..<ch { w[c] = Float(q[c] / n) }
                    }
                }
            }
        }
    }

    // MARK: Surfaces

    /// The level-`level` reduction of `s` over `rect` (level pixels; nil: everything `s` holds): a
    /// surface of the same format and default pixel whose pixel (x, y) is the block mean of `s` over
    /// [x·2^L, (x+1)·2^L) × [y·2^L, (y+1)·2^L). Blocks come from (and go to) `ReducedTiles.shared`.
    static func surface(_ s: Surface, level: Int, over rect: PixelRect? = nil, sampled: Bool = false) -> Surface {
        if level <= 0 { return s }
        var out = Surface(format: s.format, defaultPixel: s.defaultPixelValue)
        var todo: [(TileCoord, Tile)] = []
        if let rect {
            if rect.isEmpty { return out }
            for c in LevelOfDetail.documentRect(rect, level: level).tiles { if let t = s.tile(c) { todo.append((c, t)) } }
        } else {
            s.forEachTile { c, t in todo.append((c, t)) }
        }
        if todo.isEmpty { return out }
        let side = blockSide(level), fmt = s.format
        var blocks = [[UInt8]](repeating: [], count: todo.count)
        blocks.withUnsafeMutableBufferPointer { bp in
            let B = UnsafeSendable(bp)
            let T = todo
            DispatchQueue.concurrentPerform(iterations: T.count) { i in
                B.value[i] = ReducedTiles.shared.block(T[i].1, format: fmt, level: level, sampled: sampled)
            }
        }
        for (i, (c, _)) in todo.enumerated() {
            let x0 = c.tx * Int32(side), y0 = c.ty * Int32(side)
            out.writeInterleaved(PixelRect(x0: x0, y0: y0, x1: x0 + Int32(side), y1: y0 + Int32(side)), blocks[i])
        }
        return out
    }

    // MARK: Images

    /// A derived image (`img` over its rect, `outside` beyond it) reduced at `level`: over the level
    /// pixels covering its rect, where the source pixels a block reaches past the rect count as
    /// `outside`. 1 channel: plain means (masks, coverage, shapes); 2 and 4 channels: alpha-weighted
    /// colour; 3: plain means.
    static func image(_ img: FloatImage, outside: SIMD4<Float>, level: Int) -> FloatImage {
        if level <= 0 { return img }
        let r = LevelOfDetail.region(img.rect, level: level)
        let ch = img.channels
        var out = FloatImage(rect: r, channels: ch)
        if r.isEmpty { return out }
        let f = Int32(1) << Int32(level)
        let n = Float(f * f)
        let alpha = ch == 2 || ch == 4
        let cc = alpha ? ch - 1 : ch
        let outsideCh: [Float] = {
            switch ch {
            case 1: [outside.x]
            case 2: [outside.x, outside.w]
            case 3: [outside.x, outside.y, outside.z]
            default: [outside.x, outside.y, outside.z, outside.w]
            }
        }()
        let src = img
        out.data.withUnsafeMutableBufferPointer { op in
            let O = UnsafeSendable(op)
            DispatchQueue.concurrentPerform(iterations: r.height) { j in
                let ly = r.y0 + Int32(j)
                var sums = [Float](repeating: 0, count: ch)
                for i in 0..<r.width {
                    let lx = r.x0 + Int32(i)
                    for k in 0..<ch { sums[k] = 0 }
                    for sy in (ly * f)..<(ly * f + f) {
                        for sx in (lx * f)..<(lx * f + f) {
                            let inside = src.rect.contains(x: sx, y: sy)
                            let base = inside ? src.index(x: sx, y: sy) : 0
                            @inline(__always) func v(_ k: Int) -> Float { inside ? src.data[base + k] : outsideCh[k] }
                            if alpha {
                                let a = max(v(cc), 0)
                                for k in 0..<cc { sums[k] += v(k) * a }
                                sums[cc] += v(cc)
                            } else {
                                for k in 0..<ch { sums[k] += v(k) }
                            }
                        }
                    }
                    let o = (j * r.width + i) * ch
                    if alpha {
                        let w = max(sums[cc], 0)
                        for k in 0..<cc { O.value[o + k] = w > 0 ? sums[k] / w : 0 }
                        O.value[o + cc] = sums[cc] / n
                    } else {
                        for k in 0..<ch { O.value[o + k] = sums[k] / n }
                    }
                }
            }
        }
        return out
    }
}

/// Reduced blocks of tiles kept across renders, by (tile generation, level, format), least recently
/// used first out under `budget`. Readers that would otherwise reduce a tile again (CPU renders at a
/// level, nested effect-shape renders, rebuilding an evicted page) share them. Registered with
/// `MemoryPressureRelay` (a warning halves it, critical empties it).
public final class ReducedTiles: @unchecked Sendable {
    public static let shared = ReducedTiles()

    struct Key: Hashable { let generation: UInt64; let level: UInt8; let sampled: Bool; let format: PixelFormat }

    private final class Shard: @unchecked Sendable {
        let lock = NSLock()
        var entries: [Key: (bytes: [UInt8], tick: UInt64)] = [:]
        var held = 0
        var tick: UInt64 = 0
    }

    private let shards = (0..<16).map { _ in Shard() }
    private let budgetLock = NSLock()
    private var budgetBytes: Int
    private var pressure: MemoryPressureRegistration?

    /// Bytes the blocks may hold (default 256 MiB).
    public var budget: Int {
        get { budgetLock.lock(); defer { budgetLock.unlock() }; return budgetBytes }
        set { budgetLock.lock(); budgetBytes = max(newValue, 0); budgetLock.unlock(); for s in shards { s.lock.lock(); evict(s); s.lock.unlock() } }
    }

    init(budget: Int = 256 << 20) {
        budgetBytes = budget
        pressure = MemoryPressureRelay.shared.register("PCRender reduced tiles") { [weak self] level in self?.trim(level) ?? 0 }
    }

    private func shard(_ k: Key) -> Shard {
        var h = k.generation &* 0x9e37_79b9_7f4a_7c15
        h ^= h >> 29
        return shards[Int(h & 15)]
    }

    /// Bytes held.
    public var bytes: Int { shards.reduce(0) { r, s in s.lock.lock(); defer { s.lock.unlock() }; return r + s.held } }

    /// Drops every block.
    public func purge() { for s in shards { s.lock.lock(); s.entries.removeAll(); s.held = 0; s.lock.unlock() } }

    /// Trims for memory pressure: to half on a warning, everything when critical; returns the bytes freed.
    @discardableResult
    public func trim(_ level: MemoryPressureRelay.Level) -> Int {
        var freed = 0
        for s in shards {
            s.lock.lock()
            let before = s.held
            if level == .critical { s.entries.removeAll(); s.held = 0 } else { evict(s, to: s.held / 2) }
            freed += before - s.held
            s.lock.unlock()
        }
        return freed
    }

    /// The cached block, or nil.
    func cached(_ tile: Tile, format: PixelFormat, level: Int, sampled: Bool = false) -> [UInt8]? {
        let k = Key(generation: tile.generation, level: UInt8(level), sampled: sampled, format: format)
        let s = shard(k)
        s.lock.lock(); defer { s.lock.unlock() }
        guard let e = s.entries[k] else { return nil }
        s.tick += 1
        s.entries[k] = (e.bytes, s.tick)
        return e.bytes
    }

    /// `tile`'s block at `level` (packed rows), reduced now if it isn't held (and then kept).
    func block(_ tile: Tile, format: PixelFormat, level: Int, sampled: Bool = false) -> [UInt8] {
        if let hit = cached(tile, format: format, level: level, sampled: sampled) { return hit }
        let side = TileReduction.blockSide(level), row = side * format.bytesPerPixel
        let bytes = [UInt8](unsafeUninitializedCapacity: side * row) { buf, made in
            tile.bytes.withUnsafeBytes {
                TileReduction.block($0.baseAddress!, format: format, level: level, sampled: sampled, into: UnsafeMutableRawPointer(buf.baseAddress!), rowBytes: row)
            }
            made = side * row
        }
        store(tile, format: format, level: level, sampled: sampled, bytes)
        return bytes
    }

    func store(_ tile: Tile, format: PixelFormat, level: Int, sampled: Bool = false, _ bytes: [UInt8]) {
        let k = Key(generation: tile.generation, level: UInt8(level), sampled: sampled, format: format)
        let s = shard(k)
        s.lock.lock(); defer { s.lock.unlock() }
        s.tick += 1
        if let old = s.entries[k] { s.held -= old.bytes.count }
        s.entries[k] = (bytes, s.tick)
        s.held += bytes.count
        evict(s)
    }

    /// Evicts the shard's oldest quarter at a time until it is within its share (or `target`).
    private func evict(_ s: Shard, to target: Int? = nil) {
        budgetLock.lock(); let share = budgetBytes / 16; budgetLock.unlock()
        let limit = target ?? share
        if s.held <= limit { return }
        let order = s.entries.sorted { $0.value.tick < $1.value.tick }
        var i = 0
        let goal = target ?? limit * 3 / 4
        while s.held > goal, i < order.count {
            s.held -= order[i].value.bytes.count
            s.entries.removeValue(forKey: order[i].key)
            i += 1
        }
    }
}
