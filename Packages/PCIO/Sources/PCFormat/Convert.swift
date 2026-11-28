// Document ⇄ manifest conversion. Binary data is routed through a `FormatSink` (save) or
// `FormatFetch` (load) keyed by BLAKE3 hash. PCDocument's `Document`, `Layer` and surfaces are not
// Codable (by design, as in photocraft): this mapping is the native format's.
// Port of photocraft-format (crates/format/src/convert.rs), MIT OR Apache-2.0, © ArtCraft Team and
// the PhotoCraft contributors.

import PCDocument
import PCFoundation

/// Where a save sends tiles and blobs.
protocol FormatSink: AnyObject {
    /// Registers a tile, returning its hash.
    func tile(_ format: PixelFormat, _ tile: Tile) -> Hash
    func blob(_ data: [UInt8]) -> Hash
}

/// Where a load gets tiles and blobs.
protocol FormatFetch: AnyObject {
    /// Canonical (little-endian) tile bytes of the given expected length.
    func tile(_ hash: String, _ len: Int) throws(FormatError) -> [UInt8]
    func blob(_ hash: String) throws(FormatError) -> [UInt8]
}

enum Convert {
    /// Deepest group nesting a bundle may hold: the one nesting limit every consumer of the layer
    /// tree shares (PCDocument's `maxGroupDepthLimit`).
    static let maxGroupDepth = maxGroupDepthLimit

    static func tooDeep() -> FormatError { .limitExceeded("layer groups nested deeper than \(maxGroupDepth)") }

    /// Refuses to save a document the loader would reject for its group nesting.
    static func checkNesting(_ layers: [Layer]) throws(FormatError) {
        // Bounded recursion: it stops at the first layer past the limit.
        func tooDeepAt(_ layers: [Layer], _ depth: Int) -> Bool {
            (depth > maxGroupDepth && !layers.isEmpty) || layers.contains { l in l.children.map { tooDeepAt($0, depth + 1) } ?? false }
        }
        if tooDeepAt(layers, 0) { throw tooDeep() }
    }

    /// Whether any layer of `layers` (groups included, hidden or not) is a filter adjustment layer:
    /// a manifest holding one is format 3 (`pcraftFilterFormatVersion`).
    static func holdsFilterAdjustment(_ layers: [Layer]) -> Bool {
        layers.contains { l in
            if case .adjustment(.filter) = l.content { return true }
            return l.children.map(holdsFilterAdjustment) ?? false
        }
    }

    static func hex(_ bytes: [UInt8]) -> String {
        let h = Array("0123456789abcdef".utf8)
        var out = [UInt8]()
        out.reserveCapacity(bytes.count * 2)
        for b in bytes {
            out.append(h[Int(b >> 4)])
            out.append(h[Int(b & 15)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    static func unhex(_ s: String) throws(FormatError) -> [UInt8] {
        let u = Array(s.utf8)
        guard u.count % 2 == 0 else { throw .corrupt("bad hex `\(s)`") }
        // Only two ASCII hex digits per byte: no sign, no whitespace (photocraft #1818).
        func digit(_ c: UInt8) -> UInt8? {
            switch c {
            case 0x30 ... 0x39: c - 0x30
            case 0x41 ... 0x46: c - 0x41 + 10
            case 0x61 ... 0x66: c - 0x61 + 10
            default: nil
            }
        }
        var out = [UInt8]()
        out.reserveCapacity(u.count / 2)
        var i = 0
        while i < u.count {
            guard let hi = digit(u[i]), let lo = digit(u[i + 1]) else { throw .corrupt("bad hex `\(s)`") }
            out.append(hi << 4 | lo)
            i += 2
        }
        return out
    }

    static func key4(_ s: String) throws(FormatError) -> PSDKey {
        let b = try unhex(s)
        guard b.count == 4 else { throw .corrupt("bad 4-byte key `\(s)`") }
        return PSDKey(b[0], b[1], b[2], b[3])
    }

    static func isValidHash(_ h: String) -> Bool {
        let u = h.utf8
        return u.count == 64 && u.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
    }

    /// Converts native-endian sample bytes to little-endian in place (and back: the swap is an
    /// involution). A no-op on little-endian machines.
    static func swapToLE(_ bytes: inout [UInt8], _ sample: SampleType) {
        guard UInt16(1).littleEndian != 1 else { return }
        let w = sample.bytes
        guard w > 1 else { return }
        var i = 0
        while i + w <= bytes.count {
            bytes[i ..< i + w].reverse()
            i += w
        }
    }

    static func tileLen(_ format: PixelFormat) -> Int { Int(tileSize) * Int(tileSize) * format.bytesPerPixel }

    // MARK: - Save

    static func surfaceM(_ s: Surface, _ sink: FormatSink) -> SurfaceM {
        let f = s.format
        var dp = s.defaultPixel
        swapToLE(&dp, f.sample)
        let tiles = s.tileCoords.compactMap { c in s.tile(c).map { TileRef(tx: c.tx, ty: c.ty, hash: sink.tile(f, $0)) } }
        return SurfaceM(format: f, default: hex(dp), tiles: tiles)
    }

    static func optBlob(_ b: [UInt8]?, _ sink: FormatSink) -> Hash? { b.map { sink.blob($0) } }

    static func maskM(_ m: LayerMask, _ sink: FormatSink) -> MaskM {
        MaskM(surface: surfaceM(m.surface, sink), enabled: m.enabled, linked: m.linked, density: m.density, feather: m.feather)
    }

    static func videoM(_ v: VideoData, _ sink: FormatSink) -> VideoDataM {
        VideoDataM(frames: v.frames.map { surfaceM($0, sink) }, originalFrames: v.originalFrames.map { $0.map { surfaceM($0, sink) } },
                   source: v.source, fps: v.fps, showAltered: v.showAltered)
    }

    static func effectsM(_ e: Effects, _ sink: FormatSink) -> EffectsM {
        EffectsM(enabled: e.enabled, items: e.items, psdRaw: optBlob(e.psdRaw, sink), reference: e.reference)
    }

    static func layerM(_ l: Layer, _ sink: FormatSink) -> LayerM {
        // Children first, from this small frame: the conversion's large locals stay off the stack
        // that grows with each nesting level.
        var children: [LayerM] = []
        if let kids = l.children {
            children.reserveCapacity(kids.count)
            for c in kids { children.append(layerM(c, sink)) }
        }
        return layerMWith(l, children, sink)
    }

    /// One layer, given its already converted group children.
    @inline(never)
    static func layerMWith(_ l: Layer, _ children: [LayerM], _ sink: FormatSink) -> LayerM {
        let content: ContentM
        switch l.content {
        case .raster(let s):
            content = .raster(surface: surfaceM(s, sink))
        case .group(let g):
            content = .group(.init(children: children, expanded: g.expanded, artboard: g.artboard))
        case .adjustment(let a):
            content = .adjustment(a)
        case .fill(let f):
            content = .fill(f)
        case .text(let t):
            var m = ContentM.TextM(text: t.text, fontFamily: t.fontFamily, sizePt: t.sizePt, color: t.color, transform: t.transform,
                                   cache: t.cache.map { surfaceM($0, sink) }, psdRaw: optBlob(t.psdRaw, sink))
            m.runs = t.runs
            m.paragraphs = t.paragraphs
            m.shape = t.shape
            m.orientation = t.orientation
            m.antialias = t.antialias
            m.warp = t.warp
            content = .text(m)
        case .shape(let s):
            content = .shape(.init(fill: s.fill, cache: s.cache.map { surfaceM($0, sink) }, psdRaw: optBlob(s.psdRaw, sink), path: s.path,
                                   stroke: s.stroke, live: s.live))
        case .smart(let s):
            let source: SmartSourceM
            switch s.source {
            case let .embedded(fileName, bytes): source = .embedded(fileName: fileName, blob: sink.blob(bytes))
            case .linked(let path): source = .linked(path: path)
            }
            var m = ContentM.SmartM(contentsId: s.contentsId.rawValue, source: source, transform: s.transform, smartFilters: s.smartFilters,
                                    cache: s.cache.map { surfaceM($0, sink) }, psdRaw: optBlob(s.psdRaw, sink))
            m.filtersEnabled = s.filtersEnabled
            m.filterMask = s.filterMask.map { maskM($0, sink) }
            m.warp = s.warp
            m.stackMode = s.stackMode
            m.perspective = s.perspective
            content = .smart(m)
        }
        return LayerM(
            id: l.id.rawValue, name: l.name, visible: l.visible, locks: l.locks, blend: l.blend, opacity: l.opacity, fillOpacity: l.fillOpacity,
            clipped: l.clipped, mask: l.mask.map { maskM($0, sink) }, vectorMask: l.vectorMask, effects: effectsM(l.effects, sink), label: l.label,
            content: content, psdBlocks: l.psdBlocks.map { ManifestPair(hex($0.key.array), sink.blob($0.data)) }, psdId: l.psdId,
            fillCache: l.fillCache.map { FillCacheM(fill: $0.fill, surface: surfaceM($0.surface, sink)) }, linkGroup: l.linkGroup,
            excludedChannels: l.excludedChannels, blendIf: l.blendIf, advanced: l.advanced, video: l.video.map { videoM($0, sink) })
    }

    static func channelM(_ c: AlphaChannel, _ sink: FormatSink) -> ChannelM {
        ChannelM(name: c.name, surface: surfaceM(c.surface, sink), spot: c.spot.map { ManifestPair($0.color, $0.solidity) }, color: c.color,
                 opacity: c.opacity, indicates: c.indicates)
    }

    static func compM(_ c: LayerComp, _ sink: FormatSink) -> LayerCompM {
        LayerCompM(id: c.id, name: c.name, comment: c.comment, applyVisibility: c.applyVisibility, applyPosition: c.applyPosition,
                   applyAppearance: c.applyAppearance, states: c.states.map { s in
                       CompStateM(layer: s.layer.rawValue, visible: s.visible, position: s.position, appearance: s.appearance.map { a in
                           CompAppearanceM(blend: a.blend, opacity: a.opacity, fillOpacity: a.fillOpacity, effects: effectsM(a.effects, sink))
                       })
                   })
    }

    static func docM(_ d: Document, _ sink: FormatSink) -> DocM {
        var m = DocM(
            id: d.id.rawValue, name: d.name, size: d.size, resolutionDpi: d.resolutionDpi, mode: d.mode, depth: d.depth,
            iccProfile: optBlob(d.iccProfile, sink), layers: d.layers.map { layerM($0, sink) }, channels: d.channels.map { channelM($0, sink) },
            guides: d.guides, selection: d.selection.map { surfaceM($0, sink) },
            metadata: MetadataM(xmp: d.metadata.xmp, exif: optBlob(d.metadata.exif, sink), text: d.metadata.text.map { ManifestPair($0.key, $0.value) },
                                psdResources: d.metadata.psdResources.map { ManifestTriple($0.id, $0.name, sink.blob($0.data)) },
                                psdGlobalBlocks: d.metadata.psdGlobalBlocks.map { ManifestTriple(hex($0.signature.array), hex($0.key.array), sink.blob($0.data)) }),
            globalLight: d.globalLight)
        m.paths = d.paths.map { NamedPathM(name: $0.name, path: $0.path, psdRaw: optBlob($0.psdRaw, sink)) }
        m.workPath = d.workPath
        m.clippingPath = d.clippingPath
        m.quickMask = d.quickMask.map { channelM($0, sink) }
        m.quickMaskUnselected = d.quickMaskUnselected
        m.patterns = d.patterns.map { PatternM(id: $0.id, name: $0.name, width: $0.width, height: $0.height, surface: surfaceM($0.surface, sink)) }
        m.colorTable = d.colorTable
        m.duotone = d.duotone
        m.variables = d.variables
        m.timeline = d.timeline
        m.fileEncoding = d.fileEncoding
        m.layerComps = d.layerComps.map { compM($0, sink) }
        m.lastAppliedComp = d.lastAppliedComp
        m.lastDocumentState = d.lastDocumentState.map { compM($0, sink) }
        m.measurement = d.measurement
        m.notes = d.notes
        m.textStyles = d.textStyles
        m.slices = d.slices
        return m
    }

    /// Every surface a save stores, so their tiles can be hashed up front (in parallel).
    static func forEachSurface(_ d: Document, _ body: (Surface) -> Void) {
        for l in d.layers { surfaces(of: l, body) }
        d.channels.forEach { body($0.surface) }
        d.selection.map(body)
        d.quickMask.map { body($0.surface) }
        d.patterns.forEach { body($0.surface) }
    }

    static func surfaces(of l: Layer, _ body: (Surface) -> Void) {
        ownSurfaces(l, body)
        if let kids = l.children { for c in kids { surfaces(of: c, body) } }
    }

    /// A layer's own surfaces (out of line, so each nesting level costs little stack).
    @inline(never)
    static func ownSurfaces(_ l: Layer, _ body: (Surface) -> Void) {
        switch l.content {
        case .raster(let s): body(s)
        case .text(let t): t.cache.map(body)
        case .shape(let s): s.cache.map(body)
        case .smart(let s):
            s.cache.map(body)
            s.filterMask.map { body($0.surface) }
        case .group, .adjustment, .fill: break
        }
        l.mask.map { body($0.surface) }
        l.fillCache.map { body($0.surface) }
        if let v = l.video {
            v.frames.forEach(body)
            v.originalFrames?.forEach(body)
        }
    }

    /// Every surface of a manifest, in the order a load reads them.
    static func forEachSurface(_ d: DocM, _ body: (SurfaceM) -> Void) {
        for l in d.layers { surfaces(of: l, body) }
        d.channels.forEach { body($0.surface) }
        d.selection.map(body)
        d.quickMask.map { body($0.surface) }
        d.patterns.forEach { body($0.surface) }
    }

    static func surfaces(of l: LayerM, _ body: (SurfaceM) -> Void) {
        if case .group(let g) = l.content { for c in g.children { surfaces(of: c, body) } }
        ownSurfaces(l, body)
    }

    @inline(never)
    static func ownSurfaces(_ l: LayerM, _ body: (SurfaceM) -> Void) {
        switch l.content {
        case .raster(let s): body(s)
        case .text(let t): t.cache.map(body)
        case .shape(let s): s.cache.map(body)
        case .smart(let s):
            s.cache.map(body)
            s.filterMask.map { body($0.surface) }
        case .group, .adjustment, .fill: break
        }
        l.mask.map { body($0.surface) }
        l.fillCache.map { body($0.surface) }
        if let v = l.video {
            v.frames.forEach(body)
            v.originalFrames?.forEach(body)
        }
    }

    // MARK: - Load

    /// Advances the global id counter past `max` so ids loaded from a file never collide with ids
    /// minted later in this process. Returns false if `max` is implausibly far ahead (the caller
    /// then remaps ids instead).
    static func reserveIdsThrough(_ max: UInt64) -> Bool {
        let probe = LayerId.fresh().rawValue
        if max < probe { return true }
        if max - probe > 10_000_000 { return false }
        ensureIdsAbove(max)
        return true
    }
}

/// Builds a document from a manifest, fetching tiles and blobs.
final class Loader {
    let fetch: FormatFetch
    var preserveIds: Bool
    /// Stored layer id → loaded id (differs when ids are remapped), for layer comp states.
    var idMap: [UInt64: LayerId] = [:]
    var contentsIdMap: [UInt64: SmartContentsId] = [:]
    var legacyLinkedContents: [String: SmartContentsId] = [:]
    /// Decoded tiles by sample type and content hash. A save stores a tile once however often it
    /// is referenced (a solid fill shares one tile), so a load decodes and charges the byte budget
    /// once per distinct tile and hands every reference the same copy-on-write storage
    /// (photocraft #3315). Grouped by sample type: in-memory byte order depends on it.
    var tiles: [SampleType: [Hash: Tile]] = [:]

    init(fetch: FormatFetch, preserveIds: Bool) {
        self.fetch = fetch
        self.preserveIds = preserveIds
    }

    func video(_ m: VideoDataM) throws(FormatError) -> VideoData {
        var frames: [Surface] = []
        for f in m.frames { frames.append(try surface(f)) }
        if let o = m.originalFrames, o.count != frames.count {
            throw .corrupt("video original frame count differs from edited frame count")
        }
        var originals: [Surface]?
        if let o = m.originalFrames {
            var out: [Surface] = []
            for f in o { out.append(try surface(f)) }
            originals = out
        }
        var v = VideoData(frames: frames, fps: m.fps)
        v.originalFrames = originals
        v.source = m.source
        v.showAltered = m.showAltered
        return v
    }

    func surface(_ m: SurfaceM) throws(FormatError) -> Surface {
        let f = m.format
        var dp = try Convert.unhex(m.default)
        guard dp.count == f.bytesPerPixel else { throw .corrupt("default pixel has wrong size for its format") }
        Convert.swapToLE(&dp, f.sample)
        var s = Surface(format: f, defaultPixel: decodePixel(f, dp))
        let len = Convert.tileLen(f)
        // Both edges of a tile's rectangle must fit in Int32 (`TileCoord.rect` multiplies by the
        // tile size): -8388608 ... 8388606. A damaged manifest can name any index (photocraft #938).
        func fits(_ i: Int32) -> Bool {
            !i.multipliedReportingOverflow(by: tileSize).overflow && !(Int64(i) + 1).multipliedReportingOverflow(by: Int64(tileSize)).overflow
                && (Int64(i) + 1) * Int64(tileSize) <= Int64(Int32.max)
        }
        for t in m.tiles {
            guard fits(t.tx), fits(t.ty) else { throw .corrupt("tile (\(t.tx), \(t.ty)) is outside the coordinate range") }
            let c = TileCoord(tx: t.tx, ty: t.ty)
            if s.tile(c) != nil { throw .corrupt("duplicate tile (\(t.tx), \(t.ty))") }
            if let tile = tiles[f.sample]?[t.hash] {
                // One hash names one byte string, so a cached tile of another length means the same
                // hash was referenced from formats of different pixel sizes.
                guard tile.bytes.count == len else { throw .corrupt("tile \(t.hash) is referenced with different sizes") }
                s.putTiles([(c, tile)])
                continue
            }
            var bytes = try fetch.tile(t.hash, len)
            Convert.swapToLE(&bytes, f.sample)
            let tile = Tile(bytes: bytes)
            s.putTiles([(c, tile)])
            tiles[f.sample, default: [:]][t.hash] = tile
        }
        return s
    }

    func optSurface(_ m: SurfaceM?) throws(FormatError) -> Surface? {
        guard let m else { return nil }
        return try surface(m)
    }

    func optBlob(_ h: Hash?) throws(FormatError) -> [UInt8]? {
        guard let h else { return nil }
        return try fetch.blob(h)
    }

    func mask(_ m: MaskM) throws(FormatError) -> LayerMask {
        LayerMask(surface: try surface(m.surface), enabled: m.enabled, linked: m.linked, density: m.density, feather: m.feather)
    }

    func id(_ raw: UInt64) -> LayerId {
        let id = preserveIds ? LayerId(raw) : LayerId.fresh()
        idMap[raw] = id
        return id
    }

    func contentsId(_ raw: UInt64?, _ source: SmartSourceM) -> SmartContentsId {
        if let raw {
            if let id = contentsIdMap[raw] { return id }
            let id = preserveIds ? SmartContentsId(raw) : SmartContentsId.fresh()
            contentsIdMap[raw] = id
            return id
        }
        // Legacy embedded blobs may be deduplicated despite representing independent objects. Only
        // a nonempty linked path provides an existing shared-source identity.
        if case .linked(let path) = source, !path.isEmpty {
            if let id = legacyLinkedContents[path] { return id }
            let id = SmartContentsId.fresh()
            legacyLinkedContents[path] = id
            return id
        }
        return .fresh()
    }

    func effects(_ m: EffectsM) throws(FormatError) -> Effects {
        Effects(enabled: m.enabled, items: m.items, psdRaw: try optBlob(m.psdRaw), reference: m.reference)
    }

    func comp(_ m: LayerCompM) throws(FormatError) -> LayerComp {
        var states: [CompLayerState] = []
        states.reserveCapacity(m.states.count)
        for s in m.states {
            var appearance: CompAppearance?
            if let a = s.appearance {
                appearance = CompAppearance(blend: a.blend, opacity: a.opacity, fillOpacity: a.fillOpacity, effects: try effects(a.effects))
            }
            // States of layers deleted before the save keep their (now dangling) id, which
            // `layerComp.updateWarnings` reports; it must not collide with a live layer.
            let layer = idMap[s.layer] ?? LayerId(UInt64.max - min(s.layer, UInt64.max / 2))
            states.append(CompLayerState(layer: layer, visible: s.visible, position: s.position, appearance: appearance))
        }
        return LayerComp(id: m.id, name: m.name, comment: m.comment, applyVisibility: m.applyVisibility, applyPosition: m.applyPosition,
                         applyAppearance: m.applyAppearance, states: states)
    }

    func layer(_ m: LayerM, depth: Int) throws(FormatError) -> Layer {
        if depth > Convert.maxGroupDepth { throw Convert.tooDeep() }
        // Children first, from this small frame.
        var children: [Layer] = []
        if case .group(let g) = m.content {
            children.reserveCapacity(g.children.count)
            for c in g.children { children.append(try layer(c, depth: depth + 1)) }
        }
        return try layerWith(m, children)
    }

    /// One layer, given its already converted group children.
    @inline(never)
    func layerWith(_ m: LayerM, _ children: [Layer]) throws(FormatError) -> Layer {
        let content: LayerContent
        switch m.content {
        case .raster(let s):
            content = .raster(try surface(s))
        case .group(let g):
            content = .group(LayerGroup(children: children, expanded: g.expanded, artboard: g.artboard))
        case .adjustment(let a):
            content = .adjustment(a)
        case .fill(let f):
            content = .fill(f)
        case .text(let t):
            var tl = TextLayer(text: t.text, fontFamily: t.fontFamily, sizePt: t.sizePt, color: t.color)
            tl.transform = t.transform
            tl.cache = try optSurface(t.cache)
            tl.psdRaw = try optBlob(t.psdRaw)
            tl.runs = t.runs
            tl.paragraphs = t.paragraphs
            tl.shape = t.shape
            tl.orientation = t.orientation
            tl.antialias = t.antialias
            tl.warp = t.warp
            content = .text(tl)
        case .shape(let s):
            content = .shape(ShapeLayer(path: s.path, fill: s.fill, stroke: s.stroke, live: s.live, cache: try optSurface(s.cache),
                                        psdRaw: try optBlob(s.psdRaw)))
        case .smart(let s):
            let cid = contentsId(s.contentsId, s.source)
            let source: SmartSource
            switch s.source {
            case let .embedded(fileName, blob): source = .embedded(fileName: fileName, bytes: try fetch.blob(blob))
            case .linked(let path): source = .linked(path: path)
            }
            var so = SmartObject(source: source, transform: s.transform, cache: nil)
            so.contentsId = cid
            so.smartFilters = s.smartFilters
            so.cache = try optSurface(s.cache)
            so.psdRaw = try optBlob(s.psdRaw)
            so.filtersEnabled = s.filtersEnabled
            if let fm = s.filterMask { so.filterMask = try mask(fm) }
            so.warp = s.warp.flatMap { w in (w.mesh?.isValid ?? true) ? w : nil }
            so.stackMode = s.stackMode
            so.perspective = s.perspective.flatMap { p in p.count == 9 && p.allSatisfy(\.isFinite) ? p : nil }
            content = .smart(so)
        }
        var l = Layer(name: m.name, content: content)
        if let mm = m.mask { l.mask = try mask(mm) }
        if let fc = m.fillCache { l.fillCache = FillCache(fill: fc.fill, surface: try surface(fc.surface)) }
        var blocks: [PSDLayerBlock] = []
        blocks.reserveCapacity(m.psdBlocks.count)
        for b in m.psdBlocks { blocks.append(PSDLayerBlock(key: try Convert.key4(b.a), data: try fetch.blob(b.b))) }
        l.id = id(m.id)
        l.visible = m.visible
        l.locks = m.locks
        l.blend = m.blend
        l.opacity = m.opacity
        l.fillOpacity = m.fillOpacity
        l.clipped = m.clipped
        l.vectorMask = m.vectorMask
        l.effects = try effects(m.effects)
        l.label = m.label
        l.psdBlocks = blocks
        l.psdId = m.psdId
        l.linkGroup = m.linkGroup
        l.excludedChannels = m.excludedChannels
        l.blendIf = m.blendIf
        l.advanced = m.advanced
        if let v = m.video { l.video = try video(v) }
        return l
    }

    func channel(_ c: ChannelM) throws(FormatError) -> AlphaChannel {
        var a = AlphaChannel(name: c.name, surface: try surface(c.surface))
        a.spot = c.spot.map { SpotInk(color: $0.a, solidity: $0.b) }
        a.color = c.color
        a.opacity = c.opacity
        a.indicates = c.indicates
        return a
    }

    func document(_ m: DocM) throws(FormatError) -> Document {
        // Check the whole layer tree before decoding payloads or allocating ids. Remapping cannot
        // repair duplicate layer ids: layer comp and slice targets would still be ambiguous
        // (photocraft `87da091f2`).
        func checkIds(_ layers: [LayerM], _ depth: Int, _ seen: inout Set<UInt64>, _ max: inout UInt64) throws(FormatError) {
            if depth > Convert.maxGroupDepth && !layers.isEmpty { throw Convert.tooDeep() }
            for l in layers {
                if !seen.insert(l.id).inserted { throw .corrupt("duplicate layer id \(l.id)") }
                max = Swift.max(max, l.id)
                switch l.content {
                case .group(let g): try checkIds(g.children, depth + 1, &seen, &max)
                // Contents identities repeat on purpose for shared smart objects; embedded
                // documents are opaque blobs with their own layer identities.
                case .smart(let s): if let id = s.contentsId { max = Swift.max(max, id) }
                default: break
                }
            }
        }
        var max = m.id
        var seen = Set<UInt64>()
        try checkIds(m.layers, 0, &seen, &max)
        // Reserve every stored id before allocating identities missing from older bundles. If an
        // id is implausibly large, remap the whole document while keeping shared contents groups.
        if preserveIds { preserveIds = Convert.reserveIdsThrough(max) }
        var layers: [Layer] = []
        layers.reserveCapacity(m.layers.count)
        for l in m.layers { layers.append(try layer(l, depth: 0)) }
        var channels: [AlphaChannel] = []
        for c in m.channels { channels.append(try channel(c)) }
        let quickMask = try m.quickMask.map { (c) throws(FormatError) in try channel(c) }
        var md = Metadata(xmp: m.metadata.xmp, exif: try optBlob(m.metadata.exif), text: m.metadata.text.map { MetadataText($0.a, $0.b) })
        for r in m.metadata.psdResources { md.psdResources.append(PSDResource(id: r.a, name: r.b, data: try fetch.blob(r.c))) }
        for g in m.metadata.psdGlobalBlocks {
            md.psdGlobalBlocks.append(PSDGlobalBlock(signature: try Convert.key4(g.a), key: try Convert.key4(g.b), data: try fetch.blob(g.c)))
        }
        var paths: [NamedPath] = []
        for p in m.paths { paths.append(NamedPath(name: p.name, path: p.path, psdRaw: try optBlob(p.psdRaw))) }
        var patterns: [Pattern] = []
        for p in m.patterns {
            // Sizes come from the file: a pattern with no tiles can claim any size, and renderers
            // allocate per pixel.
            let max = Pattern.maxEdge
            if p.width == 0 || p.height == 0 { throw .corrupt("pattern `\(p.name)` is \(p.width)×\(p.height) px") }
            if p.width > max || p.height > max {
                throw .limitExceeded("pattern `\(p.name)` is \(p.width)×\(p.height) px (max \(max) per side)")
            }
            patterns.append(Pattern(id: p.id, name: p.name, width: p.width, height: p.height, surface: try surface(p.surface)))
        }
        var comps: [LayerComp] = []
        for c in m.layerComps { comps.append(try comp(c)) }
        let lastState = try m.lastDocumentState.map { (c) throws(FormatError) in try comp(c) }
        // Layer-based slices follow their layer through id remapping; a dangling one becomes a
        // user slice (its rect stays where it was).
        var slices = m.slices
        for i in slices.list.indices {
            if let l = slices.list[i].layer {
                slices.list[i].layer = idMap[l.rawValue]
                if slices.list[i].layer == nil && slices.list[i].origin == .layer { slices.list[i].origin = .user }
            }
        }
        var d = Document(name: m.name, size: m.size, mode: m.mode, depth: m.depth)
        d.id = preserveIds ? DocId(m.id) : DocId.fresh()
        d.resolutionDpi = m.resolutionDpi
        d.iccProfile = try optBlob(m.iccProfile)
        d.layers = layers
        d.channels = channels
        d.guides = m.guides
        d.selection = try optSurface(m.selection)
        d.metadata = md
        d.globalLight = m.globalLight
        d.paths = paths
        d.workPath = m.workPath
        d.clippingPath = m.clippingPath
        d.quickMask = quickMask
        d.quickMaskUnselected = m.quickMaskUnselected
        d.patterns = patterns
        d.colorTable = m.colorTable
        d.duotone = m.duotone
        d.variables = m.variables
        d.timeline = m.timeline
        d.fileEncoding = m.fileEncoding
        d.layerComps = comps
        d.lastAppliedComp = m.lastAppliedComp
        d.lastDocumentState = lastState
        d.measurement = m.measurement
        d.notes = m.notes
        d.textStyles = m.textStyles
        d.slices = slices
        return d
    }
}
