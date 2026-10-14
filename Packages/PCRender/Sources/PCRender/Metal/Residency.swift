// Port of photocraft-gpu (crates/gpu/src/lib.rs residency: `Resident`, `sync`, `evict`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// GPU residency of leaves. Document surfaces live in page textures (one per leaf, page cell and
// role) covering their allocated tiles; a tile is uploaded only when its `Tile.generation` changed
// (a brush dab re-uploads the touched 256² tiles, undo swaps them back). RGBA8 / RGBA16 / RGBA32F
// tiles and Gray8/16/32F masks upload without conversion; other models go through `readRGBA`.
// Rendered images (vector coverage, effect shapes) upload once per version. Pages over the memory
// budget are evicted least recently used first, never one the current render uses (eviction counts
// logical bytes, area × bytes per pixel). For the canvas's memory declaration, Metal's allocation
// sizes are reported per kind (cell pages, leaf images, feathered-mask gather pages), and pages can
// be shed by key (`MetalCompositor.relieve`).
//
// Levels of detail (AB-T-0256): a `.reduced` leaf's pages cover a level cell in level pixels and
// hold each source tile's block (TileReduction.swift), rewritten only when that tile's generation
// changed. They are linear textures over shared buffers, so blocks are reduced in parallel straight
// into the page's memory. Keys carry the level, so a leaf's pages at different levels (and its full-
// resolution pages) are separate entries.

import Foundation
import Metal
import PCFoundation

/// Where a leaf sits on the GPU for one cell: its texture (nil: only its outside value), the
/// texture's document placement and the value outside it.
struct LeafBinding {
    var texture: (any MTLTexture)?
    var origin: SIMD2<Int32>
    var size: SIMD2<Int32>
    var outside: SIMD4<Float>
}

final class ResidencyCache: @unchecked Sendable {
    let device: any MTLDevice
    /// Bytes resident pages may hold.
    var budget: Int
    /// A tighter cap set by the compositor (memory budget, relief); nil: `budget`.
    var cap: Int?
    /// Entries a capped eviction never takes (the views' visible pages).
    var protected: Set<Key> = []
    /// Above 0 while an effect shape is rendered: what it binds counts as gather (built from, not
    /// shown), unless a cell binds it too (`mark`).
    var building = 0

    /// An entry bound in this frame. A cell's bind makes it shown in this frame (what a view's render
    /// uses, `keys(usedIn:)`) and not gather; a mask build's marks it gather; an effect shape's render
    /// marks gather only an entry it made, and never shows one.
    private func mark(_ e: Entry, gather: Bool, made: Bool) {
        e.used = frame
        if gather {
            e.gather = true
        } else if building > 0 {
            if made { e.gather = true }
        } else {
            e.gather = false
            e.shown = frame
        }
    }
    private var entries: [Key: Entry] = [:]
    private var frame: UInt64 = 0
    /// The level of detail of the current render (keys its leaf images).
    private var frameLevel = 0
    /// Tiles uploaded since creation (tests, profiling); a reduced block counts as one.
    private(set) var tilesUploaded = 0
    /// Source tiles reduced into level pages since creation (tests, profiling).
    private(set) var blocksReduced = 0

    struct Key: Hashable {
        let leaf: LeafID
        let cell: SIMD2<Int32>
        let values: Bool
        /// Level of detail (0: full resolution), and whether its blocks are sampled.
        var level = 0
        var sampled = false
    }

    final class Entry {
        var texture: any MTLTexture
        /// The buffer under a level page's linear texture.
        var buffer: (any MTLBuffer)?
        var rowBytes = 0
        var rect: PixelRect
        var format: PixelFormat?
        var defaultBits: [UInt32]
        var generations: [TileCoord: UInt64]
        /// A level page's source-tile generations, row-major over the tiles its area covers (`UInt64.max`:
        /// not written yet, 0: the default pixel): a dense grid, as a page holds thousands of blocks.
        var grid: [UInt64] = []
        var version: UInt64
        var bytes: Int
        /// Metal's allocation size of `texture` (of its buffer for a level page).
        let allocated: Int
        var used: UInt64
        /// The frame a cell last bound it in.
        var shown: UInt64 = 0
        /// Bound last by a feathered mask's build or an effect shape's render, not by a cell (a warm
        /// frame doesn't read it).
        var gather = false
        init(texture: any MTLTexture, buffer: (any MTLBuffer)? = nil, rect: PixelRect, format: PixelFormat?, defaultBits: [UInt32], version: UInt64, bytes: Int) {
            self.texture = texture; self.buffer = buffer; self.rect = rect; self.format = format; self.defaultBits = defaultBits
            self.generations = [:]; self.version = version; self.bytes = bytes; self.used = 0
            allocated = buffer?.allocatedSize ?? texture.allocatedSize
        }
    }

    /// Bytes by kind: cell pages of surfaces, derived leaf images, mask gather pages; of the pages,
    /// those at a level of detail.
    struct Bytes: Equatable {
        var pages = 0, images = 0, gather = 0, levelPages = 0
        var total: Int { pages + images + gather }
    }

    init(device: any MTLDevice, budget: Int) { self.device = device; self.budget = budget }

    var residentBytes: Int { entries.values.reduce(0) { $0 + $1.bytes } }

    func purge() { entries.removeAll() }

    /// Starts a render at `level` (entries used from now on are not evicted until the next one).
    func beginFrame(level: Int = 0) { frame += 1; frameLevel = level }

    /// The current render's frame number.
    var currentFrame: UInt64 { frame }

    /// Allocated bytes by kind, of every entry or of `keys` only.
    func bytes(of keys: Set<Key>? = nil) -> Bytes {
        var b = Bytes()
        for (k, e) in entries where keys?.contains(k) ?? true {
            if e.gather {
                b.gather += e.allocated
            } else if k.cell.x == Int32.min {
                b.images += e.allocated
            } else {
                b.pages += e.allocated
                if k.level > 0 { b.levelPages += e.allocated }
            }
        }
        return b
    }

    /// Allocated bytes of every entry.
    var allocatedBytes: Int { entries.values.reduce(0) { $0 + $1.allocated } }

    /// Pages and images the render of `frame` bound for its cells (gather pages excluded).
    func keys(usedIn frame: UInt64) -> Set<Key> {
        Set(entries.compactMap { $0.value.shown == frame ? $0.key : nil })
    }

    /// Drops every entry not in `keep`; returns the allocated bytes dropped.
    @discardableResult
    func drop(keeping keep: Set<Key>) -> Int {
        var freed = 0
        for (k, e) in entries where !keep.contains(k) {
            freed += e.allocated
            entries.removeValue(forKey: k)
        }
        return freed
    }

    /// The texture format a surface's tiles upload to without conversion, if any.
    static func directFormat(_ f: PixelFormat, values: Bool) -> MTLPixelFormat? {
        if values {
            guard f.channels == 1 else { return nil }
            switch f.sample { case .u8: return .r8Unorm; case .u16: return .r16Unorm; case .f32: return .r32Float }
        }
        guard f.mode == .rgb, f.alpha else { return nil }
        switch f.sample { case .u8: return .rgba8Unorm; case .u16: return .rgba16Unorm; case .f32: return .rgba32Float }
    }

    static func bytesPerPixel(_ f: MTLPixelFormat) -> Int {
        switch f {
        case .r8Unorm: 1
        case .r16Unorm: 2
        case .r32Float, .rgba8Unorm: 4
        case .rgba16Unorm, .rgba16Float: 8
        default: 16
        }
    }

    /// The outside (default-pixel) value of a surface as RGBA, or channel 0 for values.
    static func surfaceOutside(_ s: Surface, values: Bool) -> SIMD4<Float> {
        if values { let v = s.defaultPixelValue.first ?? 0; return SIMD4(v, 0, 0, 1) }
        let probe = Surface(format: s.format, defaultPixel: s.defaultPixelValue)
        return probe.readRGBA(PixelRect(x: 0, y: 0, width: 1, height: 1))[0]
    }

    /// Binds `leaf` for the document area `cell` (a page cell or an image's rect); `gather`: for a
    /// feathered mask's build rather than a cell.
    func bind(_ id: LeafID, _ leaf: RenderLeaf, values: Bool, cell: PixelRect, gather: Bool = false) -> LeafBinding {
        switch leaf {
        case .surface(let s): return bindSurface(id, s, values: values, cell: cell, gather: gather)
        case let .reduced(s, level, sampled): return bindReduced(id, s, level: level, sampled: sampled, values: values, cell: cell, gather: gather)
        case let .image(img, outside, version): return bindImage(id, img, outside: outside, version: version, values: values, gather: gather)
        }
    }

    private func makeTexture(_ w: Int, _ h: Int, _ f: MTLPixelFormat) -> (any MTLTexture)? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: f, width: max(1, w), height: max(1, h), mipmapped: false)
        d.usage = [.shaderRead]
        d.storageMode = .shared
        return device.makeTexture(descriptor: d)
    }

    private func bindImage(_ id: LeafID, _ img: FloatImage, outside: SIMD4<Float>, version: UInt64, values: Bool, gather: Bool) -> LeafBinding {
        let key = Key(leaf: id, cell: SIMD2(Int32.min, Int32.min), values: values, level: frameLevel)
        let rect = img.rect
        if rect.isEmpty { return LeafBinding(texture: nil, origin: .zero, size: .zero, outside: outside) }
        if let e = entries[key], e.version == version, e.rect == rect {
            mark(e, gather: gather, made: false)
            return LeafBinding(texture: e.texture, origin: SIMD2(rect.x0, rect.y0), size: SIMD2(Int32(rect.width), Int32(rect.height)), outside: outside)
        }
        let fmt: MTLPixelFormat = values ? .r32Float : .rgba32Float
        guard let tex = makeTexture(rect.width, rect.height, fmt) else { return LeafBinding(texture: nil, origin: .zero, size: .zero, outside: outside) }
        if values {
            let v = LeafReader.values(.image(img, outside: outside, version: version), rect)
            v.withUnsafeBytes { tex.replace(region: MTLRegionMake2D(0, 0, rect.width, rect.height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: rect.width * 4) }
        } else {
            let px = LeafReader.rgba(.image(img, outside: outside, version: version), rect)
            px.withUnsafeBytes { tex.replace(region: MTLRegionMake2D(0, 0, rect.width, rect.height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: rect.width * 16) }
        }
        let e = Entry(texture: tex, rect: rect, format: nil, defaultBits: [], version: version, bytes: rect.area * ResidencyCache.bytesPerPixel(fmt))
        mark(e, gather: gather, made: true)
        entries[key] = e
        evict()
        return LeafBinding(texture: tex, origin: SIMD2(rect.x0, rect.y0), size: SIMD2(Int32(rect.width), Int32(rect.height)), outside: outside)
    }

    private func bindSurface(_ id: LeafID, _ s: Surface, values: Bool, cell: PixelRect, gather: Bool) -> LeafBinding {
        let outside = ResidencyCache.surfaceOutside(s, values: values)
        // The tile area inside the cell (rounded out to whole tiles).
        let tiles = cell.tiles
        let aligned = tiles.isEmpty ? PixelRect.empty : tiles.first!.rect.union(tiles.last!.rect)
        let area = s.tileBounds.intersect(aligned)
        if area.isEmpty { return LeafBinding(texture: nil, origin: .zero, size: .zero, outside: outside) }
        let key = Key(leaf: id, cell: SIMD2(aligned.x0, aligned.y0), values: values)
        let direct = ResidencyCache.directFormat(s.format, values: values)
        let fmt = direct ?? (values ? .r32Float : .rgba32Float)
        let defaultBits = s.defaultPixelValue.map(\.bitPattern)
        var entry = entries[key]
        if let e = entry, e.rect != area || e.format != s.format || e.defaultBits != defaultBits || e.texture.pixelFormat != fmt {
            entry = nil
        }
        var made = false
        if entry == nil {
            guard let tex = makeTexture(area.width, area.height, fmt) else { return LeafBinding(texture: nil, origin: .zero, size: .zero, outside: outside) }
            let e = Entry(texture: tex, rect: area, format: s.format, defaultBits: defaultBits, version: 0, bytes: area.area * ResidencyCache.bytesPerPixel(fmt))
            entries[key] = e
            entry = e
            made = true
        }
        guard let e = entry else { return LeafBinding(texture: nil, origin: .zero, size: .zero, outside: outside) }
        mark(e, gather: gather, made: made)
        let ts = Int(tileSize)
        let bpp = ResidencyCache.bytesPerPixel(fmt)
        var defaultTile: [UInt8]?
        for c in area.tiles {
            let tr = c.rect
            let ox = Int(tr.x0 - area.x0), oy = Int(tr.y0 - area.y0)
            let region = MTLRegionMake2D(ox, oy, ts, ts)
            if let tile = s.tile(c) {
                if e.generations[c] == tile.generation { continue }
                if direct != nil {
                    tile.bytes.withUnsafeBytes { e.texture.replace(region: region, mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: ts * bpp) }
                } else {
                    upload(converted: s, tr, values: values, into: e.texture, region: region)
                }
                e.generations[c] = tile.generation
                tilesUploaded += 1
            } else {
                if e.generations[c] == 0 { continue }
                if defaultTile == nil { defaultTile = defaultTileBytes(s, fmt: fmt, values: values, direct: direct != nil) }
                defaultTile!.withUnsafeBytes { e.texture.replace(region: region, mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: ts * bpp) }
                e.generations[c] = 0
            }
        }
        evict()
        return LeafBinding(texture: e.texture, origin: SIMD2(area.x0, area.y0), size: SIMD2(Int32(area.width), Int32(area.height)), outside: outside)
    }

    /// Binds a surface at a level of detail for the level cell `cell` (or a mask build's area): one
    /// block per source tile, rewritten when the tile's generation changed.
    private func bindReduced(_ id: LeafID, _ s: Surface, level: Int, sampled: Bool, values: Bool, cell: PixelRect, gather: Bool) -> LeafBinding {
        let outside = ResidencyCache.surfaceOutside(s, values: values)
        let none = LeafBinding(texture: nil, origin: .zero, size: .zero, outside: outside)
        let tiles = LevelOfDetail.documentRect(cell, level: level).tiles
        guard let first = tiles.first, let last = tiles.last else { return none }
        let alignedDoc = first.rect.union(last.rect)
        let areaDoc = s.tileBounds.intersect(alignedDoc)
        if areaDoc.isEmpty { return none }
        let area = LevelOfDetail.region(areaDoc, level: level), aligned = LevelOfDetail.region(alignedDoc, level: level)
        let key = Key(leaf: id, cell: SIMD2(aligned.x0, aligned.y0), values: values, level: level, sampled: sampled)
        let direct = ResidencyCache.directFormat(s.format, values: values)
        let fmt = direct ?? (values ? .r32Float : .rgba32Float)
        let bpp = ResidencyCache.bytesPerPixel(fmt)
        let defaultBits = s.defaultPixelValue.map(\.bitPattern)
        var entry = entries[key]
        if let e = entry, e.rect != area || e.format != s.format || e.defaultBits != defaultBits || e.texture.pixelFormat != fmt || e.buffer == nil {
            entry = nil
        }
        var made = false
        if entry == nil {
            made = true
            let align = max(device.minimumLinearTextureAlignment(for: fmt), 1)
            let rowBytes = (area.width * bpp + align - 1) / align * align
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: fmt, width: area.width, height: area.height, mipmapped: false)
            d.usage = [.shaderRead]
            d.storageMode = .shared
            guard let buf = device.makeBuffer(length: max(rowBytes * area.height, 16), options: .storageModeShared),
                  let tex = buf.makeTexture(descriptor: d, offset: 0, bytesPerRow: rowBytes) else { return none }
            let e = Entry(texture: tex, buffer: buf, rect: area, format: s.format, defaultBits: defaultBits, version: 0, bytes: area.area * bpp)
            e.rowBytes = rowBytes
            entries[key] = e
            entry = e
        }
        guard let e = entry, let buffer = e.buffer else { return none }
        mark(e, gather: gather, made: made)
        // The source tiles under the area, row-major.
        let ts = tileSize
        let tx0 = areaDoc.x0 / ts, ty0 = areaDoc.y0 / ts, cols = Int(areaDoc.width / Int(ts)), rows = Int(areaDoc.height / Int(ts))
        if e.grid.count != cols * rows { e.grid = [UInt64](repeating: .max, count: cols * rows) }
        var work: [(TileCoord, Tile?, Int)] = []
        e.grid.withUnsafeBufferPointer { g in
            for j in 0..<rows {
                for i in 0..<cols {
                    let c = TileCoord(tx: tx0 + Int32(i), ty: ty0 + Int32(j)), k = j * cols + i
                    if let t = s.tile(c) {
                        if g[k] != t.generation { work.append((c, t, k)) }
                    } else if g[k] != 0 {
                        work.append((c, nil, k))
                    }
                }
            }
        }
        if !work.isEmpty {
            let side = TileReduction.blockSide(level), rowBytes = e.rowBytes
            let base = UnsafeSendable(buffer.contents())
            let blockRow = side * bpp
            let fallback = ReducedBlock.defaultBlock(s, side: side, fmt: fmt, values: values, direct: direct != nil)
            let job = work
            let (format, x0, y0) = (s.format, Int(area.x0), Int(area.y0))
            DispatchQueue.concurrentPerform(iterations: job.count) { i in
                let (c, t, _) = job[i]
                let dst = base.value + (Int(c.ty) * side - y0) * rowBytes + (Int(c.tx) * side - x0) * bpp
                func copy(_ packed: UnsafeRawPointer) {
                    for r in 0..<side { (dst + r * rowBytes).copyMemory(from: packed + r * blockRow, byteCount: blockRow) }
                }
                guard let t else { fallback.withUnsafeBytes { copy($0.baseAddress!) }; return }
                if direct != nil {
                    // A sampled block costs less to make than a look-up.
                    if !sampled, let hit = ReducedTiles.shared.cached(t, format: format, level: level) {
                        hit.withUnsafeBytes { copy($0.baseAddress!) }
                    } else {
                        t.bytes.withUnsafeBytes { TileReduction.block($0.baseAddress!, format: format, level: level, sampled: sampled, into: dst, rowBytes: rowBytes) }
                    }
                } else {
                    let block = ReducedTiles.shared.cached(t, format: format, level: level, sampled: sampled)
                        ?? [UInt8](unsafeUninitializedCapacity: side * side * format.bytesPerPixel) { buf, made in
                            t.bytes.withUnsafeBytes {
                                TileReduction.block($0.baseAddress!, format: format, level: level, sampled: sampled, into: UnsafeMutableRawPointer(buf.baseAddress!),
                                                    rowBytes: side * format.bytesPerPixel)
                            }
                            made = side * side * format.bytesPerPixel
                        }
                    ReducedBlock.converted(block, format: format, side: side, values: values).withUnsafeBytes { copy($0.baseAddress!) }
                }
            }
            for (_, t, k) in work { e.grid[k] = t?.generation ?? 0 }
            tilesUploaded += work.count
            blocksReduced += work.reduce(0) { $0 + ($1.1 == nil ? 0 : 1) }
        }
        evict()
        return LeafBinding(texture: e.texture, origin: SIMD2(area.x0, area.y0), size: SIMD2(Int32(area.width), Int32(area.height)), outside: outside)
    }

    private func upload(converted s: Surface, _ tr: PixelRect, values: Bool, into tex: any MTLTexture, region: MTLRegion) {
        let ts = Int(tileSize)
        if values {
            let v = LeafReader.values(.surface(s), tr)
            v.withUnsafeBytes { tex.replace(region: region, mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: ts * 4) }
        } else {
            let px = s.readRGBA(tr)
            px.withUnsafeBytes { tex.replace(region: region, mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: ts * 16) }
        }
    }

    private func defaultTileBytes(_ s: Surface, fmt: MTLPixelFormat, values: Bool, direct: Bool) -> [UInt8] {
        let ts = Int(tileSize), n = ts * ts
        if direct {
            let px = encodePixel(s.format, s.defaultPixelValue)
            var out = [UInt8](repeating: 0, count: n * px.count)
            for i in 0..<n { for k in 0..<px.count { out[i * px.count + k] = px[k] } }
            return out
        }
        let o = ResidencyCache.surfaceOutside(s, values: values)
        if values {
            return [Float](repeating: o.x, count: n).withUnsafeBytes { Array($0) }
        }
        return [SIMD4<Float>](repeating: o, count: n).withUnsafeBytes { Array($0) }
    }

    /// Least recently used pages first, never one used in the current frame (nor, under a cap, a
    /// protected one). `frameDone`: the render has finished, so what it used but no view shows (an
    /// effect shape's pages, a mask's gather) may go too, last.
    func evict(frameDone: Bool = false) {
        let limit = cap ?? budget
        var total = residentBytes
        if total <= limit { return }
        let guarded = cap != nil
        let lru = entries.filter { (frameDone ? $0.value.shown != frame : $0.value.used != frame) && !(guarded && protected.contains($0.key)) }
            .sorted { $0.value.used < $1.value.used }
        for (k, e) in lru {
            if total <= limit { break }
            entries.removeValue(forKey: k)
            total -= e.bytes
        }
    }
}

/// Blocks of level pages in their page format.
enum ReducedBlock {
    /// A block of the surface's default pixel (`side`² pixels of `fmt`, packed).
    static func defaultBlock(_ s: Surface, side: Int, fmt: MTLPixelFormat, values: Bool, direct: Bool) -> [UInt8] {
        let n = side * side
        if direct {
            let px = encodePixel(s.format, s.defaultPixelValue)
            return SampleRunBytes.repeated(px, times: n)
        }
        let o = ResidencyCache.surfaceOutside(s, values: values)
        if values { return [Float](repeating: o.x, count: n).withUnsafeBytes { Array($0) } }
        return [SIMD4<Float>](repeating: o, count: n).withUnsafeBytes { Array($0) }
    }

    /// A packed block of `format` as straight RGBA floats (or channel 0) for a converted page.
    static func converted(_ block: [UInt8], format: PixelFormat, side: Int, values: Bool) -> [UInt8] {
        let r = PixelRect(x: 0, y: 0, width: side, height: side)
        let tmp = Surface(format: format, rect: r, interleaved: block)
        if values { return LeafReader.values(.surface(tmp), r).withUnsafeBytes { Array($0) } }
        return tmp.readRGBA(r).withUnsafeBytes { Array($0) }
    }
}

/// `pattern` repeated `times` times.
enum SampleRunBytes {
    static func repeated(_ pattern: [UInt8], times: Int) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(pattern.count * times)
        for _ in 0..<times { out.append(contentsOf: pattern) }
        return out
    }
}
