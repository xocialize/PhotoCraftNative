// Sparse, copy-on-write tiled surfaces in any PixelFormat.
// Port of photocraft-raster (crates/raster/src/lib.rs), MIT OR Apache-2.0, © ArtCraft Team and the
// PhotoCraft contributors.
//
// A Surface is an unbounded plane of 256×256 tiles. Missing tiles read as the surface's default
// pixel (transparent for layers, white for reveal-all masks). photocraft shares tiles through
// `Arc` and copies on `Arc::make_mut`; here a tile's bytes are a Swift Array, which is already
// copy-on-write, so copying a Surface is O(tiles) and a mutation copies only the touched tile.
// Each tile carries a generation stamp that changes on every mutation — the key for GPU residency
// and thumbnail caches (photocraft's tile generation counters). Copies of one tile keep its stamp,
// so one generation always means one set of bytes, wherever (and at how many coordinates) the tile
// sits: `fill` relies on that to put one shared solid tile at every whole tile it covers.
//
// The hot loops (region reads and writes, content bounds, prune) run on raw pointers with one
// format switch per row run, `memcmp`/`memcpy` and the codec tables below: they dominate every
// package's Debug test time, where per-sample generic calls cost tens of nanoseconds each. They
// give exactly the values `readSample`/`writeSample` give.

import Foundation
import Synchronization

private let generationCounter = Atomic<UInt64>(1)

@usableFromInline func nextTileGeneration() -> UInt64 {
    generationCounter.add(1, ordering: .relaxed).newValue
}

/// One tile's pixels: `tileSize² × bytesPerPixel`, row-major, interleaved channels.
public struct Tile: Sendable, Equatable {
    public var bytes: [UInt8] { didSet { generation = nextTileGeneration() } }
    /// Changes whenever the bytes change (cache key with the tile coordinate). Copies of a tile,
    /// also ones shared across coordinates, keep it: equal stamps mean equal bytes.
    public private(set) var generation: UInt64

    /// A tile holding `bytes` (`tileSize² × bytesPerPixel` of the owning surface's format).
    public init(bytes: [UInt8]) {
        self.bytes = bytes
        self.generation = nextTileGeneration()
    }

    public static func == (a: Tile, b: Tile) -> Bool { a.bytes == b.bytes }
}

/// Runs of samples between encoded bytes and normalised floats: one format switch per run.
/// Decoding goes through exact tables (`Float(v) / 255`, `Float(v) / 65535` precomputed), so the
/// values are bit-identical to `readSample`; encoding repeats `writeSample`'s arithmetic.
enum SampleRun {
    /// `Float(i) / 255` for every 8-bit value.
    static let u8Table: [Float] = (0..<256).map { Float($0) / 255 }
    /// `Float(i) / 65535` for every 16-bit value.
    static let u16Table: [Float] = (0..<65536).map { Float($0) / 65535 }

    /// Decodes `count` samples of `sample` at `src` into `dst`.
    static func decode(_ src: UnsafeRawPointer, _ sample: SampleType, _ dst: UnsafeMutablePointer<Float>, _ count: Int) {
        if count <= 0 { return }
        switch sample {
        case .u8:
            let s = src.assumingMemoryBound(to: UInt8.self)
            u8Table.withUnsafeBufferPointer { t in
                let tb = t.baseAddress!
                var i = 0
                while i < count { dst[i] = tb[Int(s[i])]; i &+= 1 }
            }
        case .u16:
            u16Table.withUnsafeBufferPointer { t in
                let tb = t.baseAddress!
                var i = 0
                while i < count { dst[i] = tb[Int(src.loadUnaligned(fromByteOffset: i &* 2, as: UInt16.self))]; i &+= 1 }
            }
        case .f32:
            UnsafeMutableRawPointer(dst).copyMemory(from: src, byteCount: count &* 4)
        }
    }

    /// Encodes `count` normalised floats at `src` into `dst` as `sample` (clamped, rounded half up,
    /// NaN → 0 for the integer types; floats stored as they are).
    static func encode(_ src: UnsafePointer<Float>, _ sample: SampleType, _ dst: UnsafeMutableRawPointer, _ count: Int) {
        if count <= 0 { return }
        switch sample {
        case .u8:
            let d = dst.assumingMemoryBound(to: UInt8.self)
            var i = 0
            while i < count {
                let v = src[i]
                // `min(max(v, 0), 1)` without generic calls (same result for every non-NaN value).
                d[i] = v.isNaN ? 0 : UInt8((v <= 0 ? 0 : (v > 1 ? 1 : v)) * 255 + 0.5)
                i &+= 1
            }
        case .u16:
            var i = 0
            while i < count {
                let v = src[i]
                let q: UInt16 = v.isNaN ? 0 : UInt16((v <= 0 ? 0 : (v > 1 ? 1 : v)) * 65535 + 0.5)
                dst.storeBytes(of: q, toByteOffset: i &* 2, as: UInt16.self)
                i &+= 1
            }
        case .f32:
            dst.copyMemory(from: UnsafeRawPointer(src), byteCount: count &* 4)
        }
    }

    /// Fills `count` bytes at `dst` with `pattern` repeated (doubling copies).
    static func repeatPattern(_ pattern: UnsafeRawPointer, length: Int, into dst: UnsafeMutableRawPointer, count: Int) {
        if count <= 0 || length <= 0 { return }
        let first = Swift.min(length, count)
        dst.copyMemory(from: pattern, byteCount: first)
        var filled = first
        while filled < count {
            let k = Swift.min(filled, count &- filled)
            (dst + filled).copyMemory(from: UnsafeRawPointer(dst), byteCount: k)
            filled &+= k
        }
    }

    /// `pattern` repeated `times` times.
    static func repeated<T>(_ pattern: [T], times: Int) -> [T] {
        let n = pattern.count * Swift.max(times, 0)
        if n == 0 { return [] }
        return [T](unsafeUninitializedCapacity: n) { buf, made in
            pattern.withUnsafeBytes { p in
                repeatPattern(p.baseAddress!, length: p.count, into: UnsafeMutableRawPointer(buf.baseAddress!), count: n * MemoryLayout<T>.stride)
            }
            made = n
        }
    }
}

public struct Surface: Sendable, Equatable {
    public let format: PixelFormat
    public private(set) var defaultPixel: [UInt8]
    private var store: [TileCoord: Tile] = [:]

    /// A transparent (all-zero) surface.
    public init(format: PixelFormat) {
        self.format = format
        self.defaultPixel = [UInt8](repeating: 0, count: format.bytesPerPixel)
    }

    /// A surface whose missing tiles read as `pixel` (normalised floats).
    public init(format: PixelFormat, defaultPixel pixel: [Float]) {
        self.format = format
        self.defaultPixel = encodePixel(format, pixel)
    }

    /// A surface holding `bytes` (interleaved, `format`) at `rect`.
    public init(format: PixelFormat, rect: PixelRect, interleaved bytes: [UInt8]) {
        self.init(format: format)
        writeInterleaved(rect, bytes)
    }

    public var channels: Int { format.channels }
    public var tileCount: Int { store.count }
    public var tileCoords: [TileCoord] { store.keys.sorted() }
    /// Every materialised tile, in no particular order (cheaper than `tileCoords` when order is irrelevant).
    public func forEachTile(_ body: (TileCoord, Tile) throws -> Void) rethrows {
        for (c, t) in store { try body(c, t) }
    }
    public func tile(_ c: TileCoord) -> Tile? { store[c] }
    public var defaultPixelValue: [Float] { decodePixel(format, defaultPixel) }

    private var tileByteCount: Int { Int(tileSize) * Int(tileSize) * format.bytesPerPixel }

    /// `pixel` (encoded) repeated over one tile row.
    private func encodedRow(_ pixel: [UInt8]) -> [UInt8] { SampleRun.repeated(pixel, times: Int(tileSize)) }

    /// A tile of one encoded pixel everywhere.
    private func solidTile(_ pixel: [UInt8]) -> Tile {
        if pixel.allSatisfy({ $0 == 0 }) { return Tile(bytes: [UInt8](repeating: 0, count: tileByteCount)) }
        return Tile(bytes: SampleRun.repeated(pixel, times: Int(tileSize) * Int(tileSize)))
    }

    private func filledTile() -> Tile { solidTile(defaultPixel) }

    /// Mutable access to a tile's bytes, materialising it from the default pixel if missing.
    /// Copies the tile only if it is shared with another surface (copy-on-write).
    public mutating func withTileBytes<R>(_ c: TileCoord, _ body: (UnsafeMutableRawBufferPointer) throws -> R) rethrows -> R {
        if store[c] == nil { store[c] = filledTile() }
        return try store[c]!.bytes.withUnsafeMutableBytes(body)
    }

    /// Puts whole tiles (e.g. restored from history).
    public mutating func putTiles(_ tiles: [(TileCoord, Tile)]) {
        for (c, t) in tiles { store[c] = t }
    }

    /// Removes and returns the tiles intersecting `r` (history snapshots).
    public mutating func takeTiles(_ r: PixelRect) -> [(TileCoord, Tile)] {
        // A rect spanning more tiles than are stored is answered from the stored ones, row-major as
        // the grid walk gives them: the grid of a sparse surface's bounds can run to billions.
        if r.tileCount > UInt64(store.count) {
            let hit = store.keys.filter { !$0.rect.intersect(r).isEmpty }.sorted { ($0.ty, $0.tx) < ($1.ty, $1.tx) }
            return hit.compactMap { c in store.removeValue(forKey: c).map { (c, $0) } }
        }
        return r.tiles.compactMap { c in store.removeValue(forKey: c).map { (c, $0) } }
    }

    public mutating func removeAllTiles() { store.removeAll() }

    /// Bounds of all materialised tiles.
    public var tileBounds: PixelRect {
        store.keys.reduce(PixelRect.empty) { $0.union($1.rect) }
    }

    /// Tile-local bounds `(x0, y0, x1, y1)` of the pixels of a tile that differ from the default
    /// row `def` (`tileSize` default pixels), or nil when none do.
    private static func differingBounds(_ p: UnsafeRawBufferPointer, _ def: UnsafeRawPointer, bpp: Int) -> (Int, Int, Int, Int)? {
        let ts = Int(tileSize), rowBytes = ts * bpp
        guard let base = p.baseAddress else { return nil }
        let rows = Swift.min(p.count / rowBytes, ts)
        var minX = ts, maxX = -1, minY = -1, maxY = -1
        var y = 0
        while y < rows {
            let row = base + y &* rowBytes
            if memcmp(row, def, rowBytes) != 0 {
                if minY < 0 { minY = y }
                maxY = y
                // Only pixels left of the current minimum or right of the current maximum can move them.
                if minX > 0, memcmp(row, def, minX &* bpp) != 0 {
                    var x = 0
                    while x < minX { if memcmp(row + x &* bpp, def, bpp) != 0 { minX = x; break }; x &+= 1 }
                }
                let from = maxX &+ 1
                if from < ts, memcmp(row + from &* bpp, def, (ts &- from) &* bpp) != 0 {
                    var x = ts &- 1
                    while x > maxX { if memcmp(row + x &* bpp, def, bpp) != 0 { maxX = x; break }; x &-= 1 }
                }
            }
            y &+= 1
        }
        return minY < 0 ? nil : (minX, minY, maxX &+ 1, maxY &+ 1)
    }

    /// Whether every byte of a tile repeats the default row `def`.
    private static func isUniform(_ p: UnsafeRawBufferPointer, _ def: UnsafeRawPointer, rowBytes: Int) -> Bool {
        guard let base = p.baseAddress else { return true }
        var o = 0
        while o < p.count {
            let n = Swift.min(rowBytes, p.count &- o)
            if memcmp(base + o, def, n) != 0 { return false }
            o &+= n
        }
        return true
    }

    /// Tight bounds of pixels that differ from the default pixel.
    public var contentBounds: PixelRect {
        if store.isEmpty { return .empty }
        let bpp = format.bytesPerPixel, ts = Int(tileSize)
        let defRow = encodedRow(defaultPixel)
        var out = PixelRect.empty
        // Tiles shared across coordinates (one generation) are scanned once.
        var seen: [UInt64: (Int, Int, Int, Int)?] = [:]
        defRow.withUnsafeBytes { d in
            let def = d.baseAddress!
            for (c, t) in store {
                let local: (Int, Int, Int, Int)?
                if let known = seen[t.generation] {
                    local = known
                } else {
                    local = t.bytes.withUnsafeBytes { Surface.differingBounds($0, def, bpp: bpp) }
                    seen[t.generation] = .some(local)
                }
                guard let (x0, y0, x1, y1) = local else { continue }
                let ox = Int(c.tx) * ts, oy = Int(c.ty) * ts
                out = out.union(PixelRect(x0: Int32(clamping: ox + x0), y0: Int32(clamping: oy + y0),
                                          x1: Int32(clamping: ox + x1), y1: Int32(clamping: oy + y1)))
            }
        }
        return out
    }

    /// Drops tiles that equal the default pixel everywhere.
    public mutating func prune() {
        if store.isEmpty { return }
        let defRow = encodedRow(defaultPixel)
        let rowBytes = defRow.count
        var uniform: [UInt64: Bool] = [:]
        var drop: [TileCoord] = []
        defRow.withUnsafeBytes { d in
            for (c, t) in store {
                let u: Bool
                if let known = uniform[t.generation] {
                    u = known
                } else {
                    u = t.bytes.withUnsafeBytes { Surface.isUniform($0, d.baseAddress!, rowBytes: rowBytes) }
                    uniform[t.generation] = u
                }
                if u { drop.append(c) }
            }
        }
        for c in drop { store.removeValue(forKey: c) }
    }

    // MARK: Pixels

    public func pixel(x: Int32, y: Int32) -> [Float] {
        let c = TileCoord(containing: x, y)
        guard let t = store[c] else { return decodePixel(format, defaultPixel) }
        let lx = Int(x) - Int(c.tx) * Int(tileSize), ly = Int(y) - Int(c.ty) * Int(tileSize)
        let ch = format.channels, sample = format.sample
        let base = ((ly * Int(tileSize) + lx) * ch) * sample.bytes
        return [Float](unsafeUninitializedCapacity: ch) { buf, n in
            t.bytes.withUnsafeBytes { p in
                precondition(base + ch * sample.bytes <= p.count, "pixel: tile too short")
                SampleRun.decode(p.baseAddress! + base, sample, buf.baseAddress!, ch)
            }
            n = ch
        }
    }

    public mutating func setPixel(x: Int32, y: Int32, _ px: [Float]) {
        let c = TileCoord(containing: x, y)
        let lx = Int(x) - Int(c.tx) * Int(tileSize), ly = Int(y) - Int(c.ty) * Int(tileSize)
        let ch = format.channels, sample = format.sample
        precondition(px.count >= ch, "setPixel: too few channels")
        let base = ((ly * Int(tileSize) + lx) * ch) * sample.bytes
        px.withUnsafeBufferPointer { s in
            withTileBytes(c) { p in SampleRun.encode(s.baseAddress!, sample, p.baseAddress! + base, ch) }
        }
    }

    /// Reads `r` as interleaved normalised floats (`r.area × channels`).
    public func readRegion(_ r: PixelRect) -> [Float] {
        let ch = format.channels
        var out = [Float](repeating: 0, count: r.area * ch)
        readRegion(r, into: &out)
        return out
    }

    /// Reads `r` into `out`, resizing it to `r.area × channels` first.
    public func readRegion(_ r: PixelRect, into out: inout [Float]) {
        let ch = format.channels, w = r.width, ts = Int(tileSize), sample = format.sample, sb = sample.bytes
        if out.count != r.area * ch { out = [Float](repeating: 0, count: r.area * ch) }
        if r.isEmpty { return }
        // One tile row of the default pixel, copied into rows that fall on missing tiles.
        let defRow = SampleRun.repeated(decodePixel(format, defaultPixel), times: ts)
        out.withUnsafeMutableBufferPointer { o in
            let ob = o.baseAddress!
            defRow.withUnsafeBufferPointer { dr in
                for c in r.tiles {
                    let tr = c.rect.intersect(r)
                    if tr.isEmpty { continue }
                    let span = tr.width * ch
                    let lx = Int(tr.x0) - Int(c.tx) * ts, oy = Int(c.ty) * ts
                    let dx = Int(tr.x0) - Int(r.x0)
                    if let t = store[c] {
                        t.bytes.withUnsafeBytes { p in
                            precondition(p.count >= tileByteCount, "readRegion: tile too short")
                            let pb = p.baseAddress!
                            var y = Int(tr.y0)
                            while y < Int(tr.y1) {
                                let src = ((y - oy) * ts + lx) * ch
                                let dst = ((y - Int(r.y0)) * w + dx) * ch
                                SampleRun.decode(pb + src * sb, sample, ob + dst, span)
                                y += 1
                            }
                        }
                    } else {
                        var y = Int(tr.y0)
                        while y < Int(tr.y1) {
                            let dst = ((y - Int(r.y0)) * w + dx) * ch
                            (ob + dst).update(from: dr.baseAddress!, count: span)
                            y += 1
                        }
                    }
                }
            }
        }
    }

    /// Writes interleaved normalised floats over `r`.
    public mutating func writeRegion(_ r: PixelRect, _ data: [Float]) {
        let ch = format.channels, w = r.width, ts = Int(tileSize), sample = format.sample, sb = sample.bytes
        precondition(data.count >= r.area * ch, "writeRegion: data too short")
        if r.isEmpty { return }
        let tbc = tileByteCount
        data.withUnsafeBufferPointer { d in
            let db = d.baseAddress!
            for c in r.tiles {
                let tr = c.rect.intersect(r)
                if tr.isEmpty { continue }
                let span = tr.width * ch
                let lx = Int(tr.x0) - Int(c.tx) * ts, oy = Int(c.ty) * ts
                let dx = Int(tr.x0) - Int(r.x0)
                withTileBytes(c) { p in
                    precondition(p.count >= tbc, "writeRegion: tile too short")
                    let pb = p.baseAddress!
                    var y = Int(tr.y0)
                    while y < Int(tr.y1) {
                        let dst = ((y - oy) * ts + lx) * ch
                        let src = ((y - Int(r.y0)) * w + dx) * ch
                        SampleRun.encode(db + src, sample, pb + dst * sb, span)
                        y += 1
                    }
                }
            }
        }
    }

    /// Reads `r` as encoded interleaved bytes in this surface's format.
    public func readInterleaved(_ r: PixelRect) -> [UInt8] {
        let bpp = format.bytesPerPixel, w = r.width, ts = Int(tileSize)
        var out = [UInt8](repeating: 0, count: r.area * bpp)
        if r.isEmpty { return out }
        let defRow = encodedRow(defaultPixel)
        out.withUnsafeMutableBytes { o in
            let ob = o.baseAddress!
            defRow.withUnsafeBytes { dr in
                for c in r.tiles {
                    let tr = c.rect.intersect(r)
                    if tr.isEmpty { continue }
                    let span = tr.width * bpp
                    let lx = Int(tr.x0) - Int(c.tx) * ts, oy = Int(c.ty) * ts
                    let dx = Int(tr.x0) - Int(r.x0)
                    let t = store[c]
                    var y = Int(tr.y0)
                    while y < Int(tr.y1) {
                        let dst = ((y - Int(r.y0)) * w + dx) * bpp
                        if let t {
                            let src = ((y - oy) * ts + lx) * bpp
                            t.bytes.withUnsafeBytes { p in
                                (ob + dst).copyMemory(from: p.baseAddress!.advanced(by: src), byteCount: span)
                            }
                        } else {
                            (ob + dst).copyMemory(from: dr.baseAddress!, byteCount: span)
                        }
                        y += 1
                    }
                }
            }
        }
        return out
    }

    /// Writes encoded interleaved bytes (this surface's format) over `r`.
    public mutating func writeInterleaved(_ r: PixelRect, _ bytes: [UInt8]) {
        let bpp = format.bytesPerPixel, w = r.width, ts = Int(tileSize)
        precondition(bytes.count >= r.area * bpp, "writeInterleaved: data too short")
        if r.isEmpty { return }
        bytes.withUnsafeBytes { s in
            for c in r.tiles {
                let tr = c.rect.intersect(r)
                if tr.isEmpty { continue }
                let span = tr.width * bpp
                let lx = Int(tr.x0) - Int(c.tx) * ts, oy = Int(c.ty) * ts
                let dx = Int(tr.x0) - Int(r.x0)
                withTileBytes(c) { p in
                    var y = Int(tr.y0)
                    while y < Int(tr.y1) {
                        let dst = ((y - oy) * ts + lx) * bpp
                        let src = ((y - Int(r.y0)) * w + dx) * bpp
                        p.baseAddress!.advanced(by: dst).copyMemory(from: s.baseAddress!.advanced(by: src), byteCount: span)
                        y += 1
                    }
                }
            }
        }
    }

    /// Fills `r` with one pixel (normalised floats). Every whole tile `r` covers gets the same
    /// copy-on-write solid tile (one allocation however large `r` is, as photocraft shares one `Arc`
    /// tile, #705). Tiles `r` covers in part are written, keeping the rest of their pixels; where
    /// such a tile did not exist yet, the rest is the default pixel, so missing edge tiles with the
    /// same filled part share one tile too (a canvas fill costs a few tiles, its edges included).
    /// A later edit copies just the tile it touches.
    public mutating func fill(_ r: PixelRect, with px: [Float]) {
        if r.isEmpty { return }
        let enc = encodePixel(format, px)
        let bpp = format.bytesPerPixel, ts = Int(tileSize)
        let row = encodedRow(enc)
        var solid: Tile?
        var edges: [PixelRect: Tile] = [:]
        let (rx0, ry0, rx1, ry1) = (Int(r.x0), Int(r.y0), Int(r.x1), Int(r.y1))
        func paint(_ p: UnsafeMutableRawBufferPointer, _ local: PixelRect) {
            let span = local.width * bpp
            row.withUnsafeBytes { rp in
                var y = Int(local.y0)
                while y < Int(local.y1) {
                    (p.baseAddress! + (y * ts + Int(local.x0)) * bpp).copyMemory(from: rp.baseAddress!, byteCount: span)
                    y += 1
                }
            }
        }
        for c in r.tiles {
            let ox = Int(c.tx) * ts, oy = Int(c.ty) * ts
            if ox >= rx0 && ox + ts <= rx1 && oy >= ry0 && oy + ts <= ry1 {
                if solid == nil { solid = solidTile(enc) }
                store[c] = solid
                continue
            }
            let tr = c.rect.intersect(r)
            if tr.isEmpty { continue }
            let local = PixelRect(x0: Int32(Int(tr.x0) - ox), y0: Int32(Int(tr.y0) - oy), x1: Int32(Int(tr.x1) - ox), y1: Int32(Int(tr.y1) - oy))
            if store[c] == nil {
                if edges[local] == nil {
                    var t = filledTile()
                    t.bytes.withUnsafeMutableBytes { paint($0, local) }
                    edges[local] = t
                }
                store[c] = edges[local]
                continue
            }
            withTileBytes(c) { paint($0, local) }
        }
    }

    /// The same pixels inside `bounds` on a surface whose missing tiles read transparent (all
    /// zero), with nothing outside `bounds` (AB-T-0422, AB-T-0423). A decoded image without an
    /// alpha channel gains an opaque one, and its default pixel with it (`converted(to:)`): an
    /// opaque default makes a tile of that colour read as no content (`contentBounds`, `prune`),
    /// unlike every layer the engine makes. Inside `bounds`, where the surface had no tile, the
    /// result holds the old default as shared solid tiles (`fill`); whole tiles inside are kept
    /// as they are. A surface already transparent by default comes back unchanged.
    public func withTransparentDefault(within bounds: PixelRect) -> Surface {
        if defaultPixel.allSatisfy({ $0 == 0 }) { return self }
        var out = Surface(format: format)
        out.fill(bounds, with: defaultPixelValue)
        var whole: [(TileCoord, Tile)] = []
        for (c, t) in store {
            let r = c.rect.intersect(bounds)
            if r.isEmpty { continue }
            if r == c.rect { whole.append((c, t)) } else { out.writeInterleaved(r, readInterleaved(r)) }
        }
        out.putTiles(whole)
        return out
    }

    /// The pixels of `content` moved by (dx, dy).
    public func translated(dx: Int32, dy: Int32, content: PixelRect) -> Surface {
        var out = Surface(format: format)
        out.defaultPixel = defaultPixel
        if !content.isEmpty { out.writeInterleaved(content.offsetBy(dx: dx, dy: dy), readInterleaved(content)) }
        return out
    }

    /// The same pixels at another sample type and/or with the alpha channel added or removed
    /// (photocraft `Surface::convert` within one colour model): colour channels convert as they
    /// are, an added alpha is opaque (1) and a removed one is dropped without compositing. The
    /// default pixel converts the same way. Colour models convert through RGBA (`readRGBA` /
    /// `writeRGBA`, or the engine's model conversions), not here.
    public func converted(to target: PixelFormat) -> Surface {
        precondition(target.mode == format.mode, "converted(to:) changes depth and alpha only, not the colour model")
        let color = format.mode.colorChannels
        let from = format.channels, to = target.channels
        func remap(_ src: UnsafePointer<Float>, _ dst: UnsafeMutablePointer<Float>, pixels: Int) {
            var i = 0
            while i < pixels {
                let s = src + i * from, d = dst + i * to
                var k = 0
                while k < color { d[k] = s[k]; k += 1 }
                if target.alpha { d[color] = format.alpha ? s[color] : 1 }
                i += 1
            }
        }
        var def = [Float](repeating: 0, count: to)
        let srcDef = decodePixel(format, defaultPixel)
        srcDef.withUnsafeBufferPointer { s in def.withUnsafeMutableBufferPointer { d in remap(s.baseAddress!, d.baseAddress!, pixels: 1) } }
        var out = Surface(format: target, defaultPixel: def)
        if store.isEmpty { return out }
        let pixels = Int(tileSize) * Int(tileSize)
        var src = [Float](repeating: 0, count: pixels * from)
        var dst = [Float](repeating: 0, count: format.alpha == target.alpha ? 0 : pixels * to)
        let outBytes = pixels * target.bytesPerPixel
        // Tiles shared across coordinates convert once and stay shared.
        var converted: [UInt64: Tile] = [:]
        for (c, t) in store {
            if let done = converted[t.generation] { out.store[c] = done; continue }
            let n = Swift.min(t.bytes.count / format.bytesPerPixel, pixels)
            src.withUnsafeMutableBufferPointer { sp in
                t.bytes.withUnsafeBytes { p in SampleRun.decode(p.baseAddress!, format.sample, sp.baseAddress!, n * from) }
            }
            let bytes = [UInt8](unsafeUninitializedCapacity: outBytes) { b, made in
                b.initialize(repeating: 0)
                src.withUnsafeBufferPointer { sp in
                    if format.alpha == target.alpha {
                        SampleRun.encode(sp.baseAddress!, target.sample, UnsafeMutableRawPointer(b.baseAddress!), n * to)
                    } else {
                        dst.withUnsafeMutableBufferPointer { dp in
                            remap(sp.baseAddress!, dp.baseAddress!, pixels: n)
                            SampleRun.encode(dp.baseAddress!, target.sample, UnsafeMutableRawPointer(b.baseAddress!), n * to)
                        }
                    }
                }
                made = outBytes
            }
            let tile = Tile(bytes: bytes)
            converted[t.generation] = tile
            out.store[c] = tile
        }
        return out
    }

    /// Writes straight sRGB RGBA over `r`, converted into this surface's model (CMYK through the
    /// managed converter in one batch).
    public mutating func writeRGBA(_ r: PixelRect, _ px: [SIMD4<Float>]) {
        precondition(px.count >= r.area, "writeRGBA: data too short")
        let ch = format.channels, n = r.area, alpha = format.alpha
        var out = [Float](repeating: 0, count: n * ch)
        out.withUnsafeMutableBufferPointer { ob in
            let o = ob.baseAddress!
            px.withUnsafeBufferPointer { pb in
                let p = pb.baseAddress!
                switch format.mode {
                case .cmyk:
                    let cmyk = ColorConvert.rgbToCMYK(batch: px.prefix(n).map { SIMD3($0.x, $0.y, $0.z) })
                    for i in 0..<n {
                        let c = cmyk[i]
                        o[i * ch] = c.x; o[i * ch + 1] = c.y; o[i * ch + 2] = c.z; o[i * ch + 3] = c.w
                        if alpha { o[i * ch + 4] = p[i].w }
                    }
                case .grayscale, .bitmap, .duotone:
                    for i in 0..<n {
                        o[i * ch] = ColorConvert.rgbToGray(SIMD3(p[i].x, p[i].y, p[i].z))
                        if alpha { o[i * ch + 1] = p[i].w }
                    }
                case .lab:
                    for i in 0..<n {
                        let l = ColorConvert.srgbToLab(SIMD3(p[i].x, p[i].y, p[i].z))
                        o[i * ch] = l.x / 100; o[i * ch + 1] = (l.y + 128) / 255; o[i * ch + 2] = (l.z + 128) / 255
                        if alpha { o[i * ch + 3] = p[i].w }
                    }
                case .rgb, .indexed, .multichannel:
                    for i in 0..<n {
                        o[i * ch] = p[i].x; o[i * ch + 1] = p[i].y; o[i * ch + 2] = p[i].z
                        if alpha { o[i * ch + 3] = p[i].w }
                    }
                }
            }
        }
        writeRegion(r, out)
    }

    /// One pixel as straight RGBA (photocraft `Surface::rgba`).
    public func rgba(x: Int32, y: Int32) -> SIMD4<Float> { readRGBA(PixelRect(x0: x, y0: y, x1: x + 1, y1: y + 1))[0] }

    /// Straight RGBA in 0…1 for display/export of any colour model (CMYK and Lab converted).
    public func readRGBA(_ r: PixelRect) -> [SIMD4<Float>] {
        let ch = format.channels, n = r.area, alpha = format.alpha
        let raw = readRegion(r)
        if format.mode == .cmyk {
            let cmyk = (0..<n).map { i in SIMD4(raw[i * ch], raw[i * ch + 1], raw[i * ch + 2], raw[i * ch + 3]) }
            let rgb = ColorConvert.cmykToRGB(batch: cmyk)
            return (0..<n).map { i in SIMD4(rgb[i], alpha ? raw[i * ch + ch - 1] : 1) }
        }
        let mode = format.mode
        return [SIMD4<Float>](unsafeUninitializedCapacity: n) { ob, made in
            raw.withUnsafeBufferPointer { rb in
                let q = rb.baseAddress, o = ob.baseAddress
                var i = 0
                while i < n {
                    let p = q! + i * ch
                    let a: Float = alpha ? p[ch - 1] : 1
                    let rgb: SIMD3<Float>
                    switch mode {
                    case .rgb, .indexed, .multichannel: rgb = SIMD3(p[0], p[1], p[2])
                    case .grayscale, .bitmap, .duotone: rgb = SIMD3(repeating: p[0])
                    case .cmyk: rgb = ColorConvert.cmykToRGB(SIMD4(p[0], p[1], p[2], p[3]))
                    case .lab: rgb = ColorConvert.labToSRGB(SIMD3(p[0] * 100, p[1] * 255 - 128, p[2] * 255 - 128))
                    }
                    (o! + i).initialize(to: SIMD4(rgb, a))
                    i += 1
                }
            }
            made = n
        }
    }

    public static func == (a: Surface, b: Surface) -> Bool {
        a.format == b.format && a.defaultPixel == b.defaultPixel && a.store == b.store
    }
}
