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
    private var entries: [Key: Entry] = [:]
    private var frame: UInt64 = 0
    /// Tiles uploaded since creation (tests, profiling).
    private(set) var tilesUploaded = 0

    struct Key: Hashable {
        let leaf: LeafID
        let cell: SIMD2<Int32>
        let values: Bool
    }

    final class Entry {
        var texture: any MTLTexture
        var rect: PixelRect
        var format: PixelFormat?
        var defaultBits: [UInt32]
        var generations: [TileCoord: UInt64]
        var version: UInt64
        var bytes: Int
        /// Metal's allocation size of `texture`.
        let allocated: Int
        var used: UInt64
        /// Bound last by a feathered mask's build (not by a cell: a warm frame doesn't read it).
        var gather = false
        init(texture: any MTLTexture, rect: PixelRect, format: PixelFormat?, defaultBits: [UInt32], version: UInt64, bytes: Int) {
            self.texture = texture; self.rect = rect; self.format = format; self.defaultBits = defaultBits
            self.generations = [:]; self.version = version; self.bytes = bytes; self.used = 0
            allocated = texture.allocatedSize
        }
    }

    /// Bytes by kind: cell pages of surfaces, derived leaf images, mask gather pages.
    struct Bytes: Equatable {
        var pages = 0, images = 0, gather = 0
        var total: Int { pages + images + gather }
    }

    init(device: any MTLDevice, budget: Int) { self.device = device; self.budget = budget }

    var residentBytes: Int { entries.values.reduce(0) { $0 + $1.bytes } }

    func purge() { entries.removeAll() }

    /// Starts a render (entries used from now on are not evicted until the next one).
    func beginFrame() { frame += 1 }

    /// The current render's frame number.
    var currentFrame: UInt64 { frame }

    /// Allocated bytes by kind, of every entry or of `keys` only.
    func bytes(of keys: Set<Key>? = nil) -> Bytes {
        var b = Bytes()
        for (k, e) in entries where keys?.contains(k) ?? true {
            if e.gather { b.gather += e.allocated } else if k.cell.x == Int32.min { b.images += e.allocated } else { b.pages += e.allocated }
        }
        return b
    }

    /// Allocated bytes of every entry.
    var allocatedBytes: Int { entries.values.reduce(0) { $0 + $1.allocated } }

    /// Pages and images the render of `frame` bound for its cells (gather pages excluded).
    func keys(usedIn frame: UInt64) -> Set<Key> {
        Set(entries.compactMap { $0.value.used == frame && !$0.value.gather ? $0.key : nil })
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
        let key = Key(leaf: id, cell: SIMD2(Int32.min, Int32.min), values: values)
        let rect = img.rect
        if rect.isEmpty { return LeafBinding(texture: nil, origin: .zero, size: .zero, outside: outside) }
        if let e = entries[key], e.version == version, e.rect == rect {
            e.used = frame
            e.gather = gather
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
        e.used = frame
        e.gather = gather
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
        if entry == nil {
            guard let tex = makeTexture(area.width, area.height, fmt) else { return LeafBinding(texture: nil, origin: .zero, size: .zero, outside: outside) }
            let e = Entry(texture: tex, rect: area, format: s.format, defaultBits: defaultBits, version: 0, bytes: area.area * ResidencyCache.bytesPerPixel(fmt))
            entries[key] = e
            entry = e
        }
        guard let e = entry else { return LeafBinding(texture: nil, origin: .zero, size: .zero, outside: outside) }
        e.used = frame
        e.gather = gather
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
    /// protected one).
    func evict() {
        let limit = cap ?? budget
        var total = residentBytes
        if total <= limit { return }
        let guarded = cap != nil
        let lru = entries.filter { $0.value.used != frame && !(guarded && protected.contains($0.key)) }.sorted { $0.value.used < $1.value.used }
        for (k, e) in lru {
            if total <= limit { break }
            entries.removeValue(forKey: k)
            total -= e.bytes
        }
    }
}
