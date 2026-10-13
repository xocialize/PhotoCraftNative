// Port of photocraft-engine (crates/engine/src/smart_cmds.rs: source encoding/decoding, the source cache, rendering, refresh, add_smart_filter, placement and conversion), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Re-rendering a smart object from its source (compose stays a pure function of the document):
//
//     source bytes ──decode (PCIO) + composite (cached by content hash)──► source image
//                  ──transform (exact shift, or bicubic warp: PCAlgo's placeSource)──► placed
//                  ──each visible smart filter, blended (blend/opacity)──► filtered
//                  ──filter mask mix (unfiltered ↔ filtered)──► cache
//
// The placed stage and the result after each filter are cached too (`StackCache`), so a
// re-render starts from the deepest stage it shares with an earlier one.
//
// Rendering needs the session's services: PCIO's decoders through the engine's glue
// (`EngineIO.importFile`) and the session's file service for linked files. Callers without a
// session (the compositor's fallback, `PlatformRasterizer`) use `decodeOnly`, which reads no files:
// a linked file is then unavailable and the cache stays, photocraft's path for a missing file.
// Sources are flattened with a private CPU compositor per decode (photocraft-compose's CPU
// reference), so a render inside the canvas compositor never waits on the engine renderer's lock.

import CryptoKit
import Foundation
import PCAlgo
import PCDocument
import PCFormat
import PCFoundation
import PCIOCore
import PCIOFormats
import PCIOSmart
import PCRender
import Synchronization

extension SmartCommands {
    // MARK: Services

    /// The services of a render without a session: PCIO's decoders, no file access.
    static let decodeOnly = EngineServices(fileSystem: DeniedFileSystem())

    // MARK: Source encoding / decoding

    /// Encodes a document as embedded smart-object contents: an in-memory `.pcraft` bundle
    /// (photocraft `encode_source`).
    static func encodeSource(_ doc: Document) throws -> [UInt8] {
        do { return try PcraftFormat.save(doc) } catch { throw other("can't encode smart object contents: \(error)") }
    }

    /// Decodes smart-object contents: a `.pcraft` bundle, PSD/PSB, or any flat image format
    /// (photocraft `decode_source`).
    static func decodeSource(_ fileName: String, _ bytes: [UInt8], services: EngineServices) throws -> Document {
        let r: ImportResult
        do { r = try EngineIO.importFile(name: fileName, bytes: bytes, services: services) } catch EngineError.cancelled {
            throw EngineError.cancelled
        } catch {
            throw other("can't read smart object contents \"\(fileName)\": \(EngineError.wrap(error))")
        }
        if r.previewOnly {
            throw other("can't read smart object contents \"\(fileName)\": only this Affinity file's embedded preview could be read")
        }
        return r.document
    }

    /// Memory-only resolution: embedded bytes, or Photoshop's embedded file addressed by a
    /// `linked` uuid in the document's `lnk2`/`lnk3`/`lnkD` blocks (photocraft
    /// `embedded_source_bytes`).
    static func embeddedSourceBytes(_ meta: Metadata, _ src: SmartSource) -> (String, [UInt8])? {
        switch src {
        case .embedded(let name, let bytes): return (name, bytes)
        case .linked(let path): return Linked.findLinkedFile(meta, path).map { ($0.fileName, $0.bytes) }
        }
    }

    /// The source file of a smart object: embedded bytes, the PSD's embedded linked-layer data
    /// (PSD import keeps the placed layer's uuid as the path), or a linked file read through `fs`
    /// (photocraft `source_bytes`).
    static func sourceBytes(_ meta: Metadata, _ src: SmartSource, fs: any FileSystemService) -> (String, [UInt8])? {
        if let e = embeddedSourceBytes(meta, src) { return e }
        guard case .linked(let path) = src, !path.isEmpty, let data = try? fs.read(path) else { return nil }
        return (baseName(path), [UInt8](data))
    }

    /// The session's gate checks a linked file's actual path before it is read: the path lives in
    /// the document, not in the command's params (photocraft `authorized_source_bytes`).
    static func authorizedSourceBytes(_ s: Session, _ cmd: String, _ meta: Metadata, _ src: SmartSource) throws -> (String, [UInt8])? {
        if let e = embeddedSourceBytes(meta, src) { return e }
        guard case .linked(let path) = src else { return nil }
        if let gate = s.authorize {
            do { try gate(cmd, ["path": .string(path)]) } catch { throw EngineError.wrap(error) }
        }
        return sourceBytes(meta, src, fs: s.services.fileSystem)
    }

    /// Rechecks a source's path before an untrusted command reads it; embedded PSD uuids never
    /// reach the file system (photocraft `authorize_source`).
    static func authorizeSource(_ s: Session, _ cmd: String, _ doc: Document, _ src: SmartSource) throws {
        if let gate = s.authorize, case .linked(let path) = src, embeddedSourceBytes(doc.metadata, src) == nil {
            do { try gate(cmd, ["path": .string(path)]) } catch { throw EngineError.wrap(error) }
        }
    }

    /// The file name and bytes of smart object `id`'s contents (photocraft `contents_of`).
    static func contentsOf(_ doc: Document, _ id: LayerId, fs: any FileSystemService) throws -> (String, [UInt8]) {
        guard let r = sourceBytes(doc.metadata, try smart(doc, id).source, fs: fs) else { throw other("the smart object's contents are unavailable") }
        return r
    }

    // MARK: Source images (decoded once, then cached)

    /// A decoded, composited source in its own pixel space (`bounds` starts at the origin).
    struct SourceImage: Sendable {
        var surface: Surface
        var bounds: PixelRect
    }

    /// SHA-256 of the contents (plus a variant for stack modes and vector scales) and the pixel
    /// format (photocraft keys by blake3).
    struct CacheKey: Hashable, Sendable {
        var digest: [UInt8]
        var format: PixelFormat
    }

    struct CacheEntry: Sendable {
        var key: CacheKey
        var image: SourceImage
        var decodes: UInt32
    }

    /// Decoded source composites by content hash, most recent last. Re-filtering or
    /// re-transforming a smart object never decodes its contents again.
    static let sourceCache = Mutex<[CacheEntry]>([])
    static let cacheEntries = 32
    static let cacheBytes = 1 << 30

    static func digest(_ bytes: [UInt8]) -> [UInt8] { Array(SHA256.hash(data: bytes)) }

    static func digest(_ base: [UInt8], _ variant: String) -> [UInt8] { digest(base + Array(variant.utf8)) }

    static func cacheGet(_ key: CacheKey) -> SourceImage? {
        sourceCache.withLock { c in
            guard let i = c.firstIndex(where: { $0.key == key }) else { return nil }
            let e = c.remove(at: i)
            c.append(e)
            return e.image
        }
    }

    static func cachePut(_ key: CacheKey, _ image: SourceImage) {
        sourceCache.withLock { c in
            var decodes: UInt32 = 1
            if let i = c.firstIndex(where: { $0.key == key }) { decodes = c.remove(at: i).decodes &+ 1 }
            c.append(CacheEntry(key: key, image: image, decodes: decodes))
            func size(_ e: CacheEntry) -> Int { e.image.bounds.area * e.key.format.channels * 4 }
            while c.count > cacheEntries || (c.count > 1 && c.reduce(0, { $0 + size($1) }) > cacheBytes) { c.removeFirst() }
        }
    }

    /// How many times these contents were decoded at this pixel format (0 = never / evicted)
    /// (photocraft `source_decode_count`).
    static func sourceDecodeCount(_ bytes: [UInt8], _ fmt: PixelFormat) -> UInt32 {
        let key = CacheKey(digest: digest(bytes), format: fmt)
        return sourceCache.withLock { c in c.first(where: { $0.key == key })?.decodes ?? 0 }
    }

    /// A private CPU compositor (photocraft-compose's reference): one per call, so nested smart
    /// objects and the canvas compositor's fallback never wait on a shared lock.
    static func compositor(_ services: EngineServices) -> PCRender.DocumentCompositor {
        PCRender.DocumentCompositor(rasterizer: services.renderer.rasterizer, backend: .cpu, metal: nil)
    }

    /// `buf` (straight RGBA) as a surface in `fmt` (photocraft `buffer_to_surface`).
    static func bufferToSurface(_ buf: RGBABuffer, _ fmt: PixelFormat) -> Surface {
        var s = Surface(format: fmt)
        if !buf.rect.isEmpty { s.writeRegion(buf.rect, PixelCodec.fromRGBA(fmt, rgba: buf.px)) }
        s.prune()
        return s
    }

    static func composite(_ doc: Document, _ region: PixelRect, _ services: EngineServices) throws -> RGBABuffer {
        do { return try compositor(services).render(doc, region: region) } catch let e as EngineError { throw e } catch {
            throw other("compositing failed: \(error)")
        }
    }

    /// The composited source image of `bytes` in pixel format `fmt`, decoded once then cached
    /// (photocraft `source_image`).
    static func sourceImage(_ fileName: String, _ bytes: [UInt8], _ fmt: PixelFormat, services: EngineServices,
                            digest d: [UInt8]? = nil) throws -> SourceImage {
        let key = CacheKey(digest: d ?? digest(bytes), format: fmt)
        if let img = cacheGet(key) { return img }
        let doc = try decodeSource(fileName, bytes, services: services)
        let img = SourceImage(surface: bufferToSurface(try composite(doc, doc.bounds, services), fmt), bounds: doc.bounds)
        cachePut(key, img)
        return img
    }

    /// Layer › Smart Objects › Stack Mode: the source's layers (or, when it holds a single group,
    /// the group's layers) combined per pixel with `mode`, cached like `sourceImage` keyed by mode
    /// (photocraft `stack_image`).
    static func stackImage(_ fileName: String, _ bytes: [UInt8], _ fmt: PixelFormat, _ mode: StackMode, services: EngineServices,
                           digest d: [UInt8]? = nil) throws -> SourceImage {
        let key = CacheKey(digest: digest(d ?? digest(bytes), "stack:" + mode.id), format: fmt)
        if let img = cacheGet(key) { return img }
        let doc = try decodeSource(fileName, bytes, services: services)
        let layers: [Layer] = doc.layers.count == 1 && doc.layers[0].isGroup ? (doc.layers[0].children ?? []) : doc.layers
        let bounds = doc.bounds
        var frames: [[SIMD4<Float>]] = []
        for l in layers where l.visible {
            var one = l
            one.blend = .normal
            one.clipped = false
            var alone = doc
            alone.layers = [one]
            frames.append(try composite(alone, bounds, services).px)
        }
        if frames.isEmpty { throw other("the smart object's contents have no visible layers") }
        let stat: StackStat = switch mode {
        case .entropy: .entropy
        case .kurtosis: .kurtosis
        case .maximum: .maximum
        case .mean: .mean
        case .median: .median
        case .minimum: .minimum
        case .range: .range
        case .skewness: .skewness
        case .standardDeviation: .standardDeviation
        case .summation: .summation
        case .variance: .variance
        }
        let px: [SIMD4<Float>]
        do { px = try Stack.combine(frames, stat) } catch { throw other("Stack Mode: \(error)") }
        let img = SourceImage(surface: bufferToSurface(RGBABuffer(rect: bounds, px: px), fmt), bounds: bounds)
        cachePut(key, img)
        return img
    }

    /// An SVG source rendered at `scale` times its own size (cached per scale), so a vector smart
    /// object stays sharp however it is placed (photocraft `svg_source_image`).
    static func svgSourceImage(_ bytes: [UInt8], _ fmt: PixelFormat, scale: Double, digest d: [UInt8]? = nil) throws -> SourceImage {
        let key = CacheKey(digest: digest(d ?? digest(bytes), "svg:\(scale.bitPattern)"), format: fmt)
        if let img = cacheGet(key) { return img }
        let r: SVGImport.Raster
        do { r = try SVGImport.rasterize(bytes, Float(scale)) } catch { throw other("can't render the SVG smart object: \(error)") }
        let rect = PixelRect(x0: 0, y0: 0, x1: Int32(clamping: r.width), y1: Int32(clamping: r.height))
        var s = Surface(format: fmt)
        if !rect.isEmpty, r.pixels.count == rect.area { s.writeRegion(rect, PixelCodec.fromRGBA(fmt, rgba: r.pixels)) }
        s.prune()
        let img = SourceImage(surface: s, bounds: rect)
        cachePut(key, img)
        return img
    }

    /// The scale a vector source is rasterised at for its placement: the larger axis scale of the
    /// transform in 1/16 steps (so nudges reuse the cache), between 1/16 and 64 (photocraft
    /// `vector_scale`).
    static func vectorScale(_ sm: SmartObject) -> Double {
        let t = sm.transform
        let x = (t.a * t.a + t.b * t.b).squareRoot(), y = (t.c * t.c + t.d * t.d).squareRoot()
        let k = x.isNaN ? y : (y.isNaN ? x : Swift.max(x, y))
        if !k.isFinite { return 1 }
        return Swift.min(Swift.max((k * 16).rounded(.up) / 16, 1.0 / 16), 64)
    }

    // MARK: Rendering

    /// `top` blended over `base` with `mode` at `opacity` (a smart filter's blending options).
    static func blendSurfaces(_ base: Surface, _ top: Surface, _ mode: BlendMode, _ opacity: Float) -> Surface {
        let fmt = base.format
        let area = base.contentBounds.union(top.contentBounds)
        var out = base
        if area.isEmpty { return out }
        let b = PixelCodec.toRGBA(fmt, raw: base.readRegion(area))
        let t = PixelCodec.toRGBA(fmt, raw: top.converted(to: fmt).readRegion(area))
        var o: [SIMD4<Float>] = []
        o.reserveCapacity(b.count)
        for i in b.indices { o.append(Blend.composite(mode, backdrop: b[i], source: i < t.count ? t[i] : .zero, opacity: opacity)) }
        out.writeRegion(area, PixelCodec.fromRGBA(fmt, rgba: o))
        out.prune()
        return out
    }

    /// Mixes `filtered` over `base` through the filter mask (premultiplied, any channel layout)
    /// (photocraft `mask_mix`).
    static func maskMix(_ base: Surface, _ filtered: Surface, _ mask: LayerMask) -> Surface {
        let fmt = base.format
        let area = base.contentBounds.union(filtered.contentBounds)
        var out = filtered
        if area.isEmpty { return out }
        let n = fmt.channels
        let b = base.readRegion(area), f = filtered.readRegion(area)
        var k: [Float] = []
        mask.values(area, into: &k)
        var o = [Float](repeating: 0, count: b.count)
        let count = Swift.min(b.count, f.count) / Swift.max(n, 1)
        for i in 0..<count {
            let m = Swift.min(Swift.max(i < k.count ? k[i] : 1, 0), 1)
            let p = i * n
            if !fmt.alpha {
                for c in 0..<n { o[p + c] = b[p + c] + (f[p + c] - b[p + c]) * m }
                continue
            }
            let a = n - 1
            let oa = b[p + a] + (f[p + a] - b[p + a]) * m
            o[p + a] = oa
            for c in 0..<a {
                let pm = b[p + c] * b[p + a] + (f[p + c] * f[p + a] - b[p + c] * b[p + a]) * m
                o[p + c] = oa > 0 ? Swift.min(Swift.max(pm / oa, 0), 1) : 0
            }
        }
        out.writeRegion(area, o)
        out.prune()
        return out
    }

    /// Runs the smart filter stack on the placed (unfiltered) content (photocraft
    /// `apply_smart_filters`). `fs` reads filter inputs (Displace's map).
    static func applySmartFilters(_ placed: Surface, _ sm: SmartObject, canvas: PixelRect, fs: (any FileSystemService)? = nil) -> Surface {
        if !sm.filtersEnabled || !sm.smartFilters.contains(where: \.visible) { return placed }
        var cur = placed
        // Edge pixels repeat at the canvas ∪ placed-content edge, as for layer filters.
        let extent = canvas.union(placed.contentBounds)
        for f in sm.smartFilters where f.visible { cur = applySmartFilter(f, cur, canvas: canvas, extent: extent, fs: fs) }
        if let m = sm.filterMask, m.enabled { return maskMix(placed, cur, m) }
        return cur
    }

    /// One visible smart filter over `cur`, blended with its blend mode and opacity. Unknown ids
    /// (e.g. Photoshop filters PhotoCraft doesn't implement) leave the pixels alone.
    static func applySmartFilter(_ f: SmartFilter, _ cur: Surface, canvas: PixelRect, extent: PixelRect, fs: (any FileSystemService)?) -> Surface {
        guard let out = FilterCommands.applyFilterToSurface(f.command, f.params, cur, bounds: canvas, selection: nil, canvas: extent, fs: fs) else {
            return cur
        }
        if f.blend == .normal && f.opacity >= 1 { return out }
        return blendSurfaces(cur, out, f.blend, Swift.min(Swift.max(f.opacity, 0), 1))
    }

    /// Places a source image through an affine transform, or a projective map, after an optional
    /// warp in source space (PCAlgo's `placeSource[Projective]`).
    static func placeImage(_ img: SourceImage, _ t: PCAffine, _ perspective: [Double]?, _ warp: Warp?) throws -> Surface {
        guard let s = EngineIO.placeSource(img.surface, img.bounds, t, perspective, warp) else { throw other("can't place the smart object's contents") }
        return s
    }

    /// The source placed in document pixels, before any smart filter (photocraft `place`).
    static func place(_ name: String, _ bytes: [UInt8], _ fmt: PixelFormat, _ sm: SmartObject, services: EngineServices,
                      digest d: [UInt8]? = nil) throws -> Surface {
        let d = d ?? digest(bytes)
        // A vector source is rendered at the placement's scale, and the placement is divided by
        // that scale so the rendered pixels land where the source units would.
        if sm.stackMode == nil && sm.warp == nil && SVGImport.isSVG(bytes) {
            let k = vectorScale(sm)
            let img = try svgSourceImage(bytes, fmt, scale: k, digest: d)
            if let p = sm.perspective, p.count == 9 {
                return try placeImage(img, .identity, [p[0] / k, p[1] / k, p[2], p[3] / k, p[4] / k, p[5], p[6] / k, p[7] / k, p[8]], nil)
            }
            let t = sm.transform
            return try placeImage(img, PCAffine(a: t.a / k, b: t.b / k, c: t.c / k, d: t.d / k, e: t.e, f: t.f), nil, nil)
        }
        let img = if let mode = sm.stackMode {
            try stackImage(name, bytes, fmt, mode, services: services, digest: d)
        } else {
            try sourceImage(name, bytes, fmt, services: services, digest: d)
        }
        // Through the warp (source space) and the transform in one pass; whole-pixel moves are exact.
        return try placeImage(img, sm.transform, sm.perspective, sm.warp)
    }

    /// Renders a smart object from its source. nil when the source is unavailable (a missing
    /// linked file, or a PSD placed layer without embedded data): callers keep the existing cache
    /// (photocraft `render`). Without `services`, files aren't read (`decodeOnly`).
    static func render(_ doc: Document, _ sm: SmartObject, services: EngineServices? = nil) throws -> Surface? {
        try renderIn(doc, sm, ctx: nil, services: services)
    }

    /// `render`, reporting progress per smart filter to `ctx` and stopping between filters once
    /// it is cancelled. Gives the same pixels as `applySmartFilters` on the placed source, but
    /// starts from the deepest stage of the stack already rendered (`StackCache`) (photocraft
    /// `render_in`).
    static func renderIn(_ doc: Document, _ sm: SmartObject, ctx: JobContext?, services: EngineServices?) throws -> Surface? {
        let svc = services ?? decodeOnly
        let fs = services?.fileSystem
        guard let (name, bytes) = sourceBytes(doc.metadata, sm.source, fs: svc.fileSystem) else { return nil }
        let (fmt, canvas) = (doc.pixelFormat, doc.bounds)
        let d = digest(bytes)
        let placedKey = StackCache.placedKey(d, fmt, sm, canvas)
        func placed() throws -> StackCache.Stage {
            if let stage = StackCache.get(placedKey) { return stage }
            let surface = try place(name, bytes, fmt, sm, services: svc, digest: d)
            // Edge pixels repeat at the canvas ∪ placed-content edge, as for layer filters.
            let stage = StackCache.Stage(surface: surface, extent: canvas.union(surface.contentBounds))
            StackCache.put(placedKey, stage)
            return stage
        }
        let filters = sm.smartFilters.filter { sm.filtersEnabled && $0.visible }
        if filters.isEmpty { return try placed().surface }
        var keys: [StackCache.Key] = []
        var key = placedKey
        for f in filters {
            key = StackCache.filterKey(key, f)
            keys.append(key)
        }
        var done = 0
        var cur: StackCache.Stage?
        for i in keys.indices.reversed() {
            if let stage = StackCache.get(keys[i]) {
                (done, cur) = (i + 1, stage)
                break
            }
        }
        var stage = try cur ?? placed()
        let n = Float(filters.count)
        for i in done..<filters.count {
            try ctx?.check()
            ctx?.progress(Float(i) / n, "")
            stage = StackCache.Stage(surface: applySmartFilter(filters[i], stage.surface, canvas: canvas, extent: stage.extent, fs: fs), extent: stage.extent)
            StackCache.put(keys[i], stage)
        }
        ctx?.progress(1, "")
        if let m = sm.filterMask, m.enabled { return maskMix(try placed().surface, stage.surface, m) }
        return stage.surface
    }

    /// The smart object's pixels below smart filter `index` (the input that filter edits): the
    /// placed source and the filters under it, without the filter mask. nil when the source is
    /// unavailable (photocraft `render_below_filter`).
    static func renderBelowFilter(_ doc: Document, _ sm: SmartObject, _ index: Int, services: EngineServices? = nil) throws -> Surface? {
        var below = sm
        below.smartFilters = Array(below.smartFilters.prefix(Swift.max(index, 0)))
        below.filterMask = nil
        return try render(doc, below, services: services)
    }

    /// Re-renders smart layer `l` (which lives in `doc`) in place. false if its source is
    /// unavailable (the cache is then left alone) (photocraft `refresh_layer`).
    @discardableResult
    static func refreshLayer(_ doc: Document, _ l: inout Layer, services: EngineServices? = nil, ctx: JobContext? = nil) throws -> Bool {
        guard case .smart(let sm) = l.content else { return false }
        guard let px = try renderIn(doc, sm, ctx: ctx, services: services) else { return false }
        l.withSmartObject { $0.cache = px }
        return true
    }

    /// Re-renders the smart object `id` of `doc` (photocraft `refresh`).
    @discardableResult
    static func refresh(_ doc: inout Document, _ id: LayerId, services: EngineServices? = nil, ctx: JobContext? = nil) throws -> Bool {
        guard var l = doc.layer(id) else { throw EngineError.noLayer(id) }
        guard case .smart = l.content else { throw other("the layer is not a smart object") }
        let ok = try refreshLayer(doc, &l, services: services, ctx: ctx)
        if ok { doc.updateLayer(id) { $0.content = l.content } }
        return ok
    }

    /// `refresh`, failing when the source can't be rendered (photocraft `refresh_or_fail`).
    static func refreshOrFail(_ doc: inout Document, _ id: LayerId, services: EngineServices? = nil, ctx: JobContext? = nil) throws {
        if try !refresh(&doc, id, services: services, ctx: ctx) {
            throw other("the smart object's contents are unavailable (missing linked file?), so it can't be re-rendered")
        }
    }

    /// Mutates smart object `id` (photocraft `smart_mut`).
    static func updateSmart<R>(_ doc: inout Document, _ id: LayerId, _ body: (inout SmartObject) throws -> R) throws -> R {
        guard doc.layer(id) != nil else { throw EngineError.noLayer(id) }
        guard let r = try doc.updateLayer(id, { l in try l.withSmartObject(body) }), let out = r else {
            throw other("the layer is not a smart object")
        }
        return out
    }

    static func maskFromSelection(_ sel: Surface) -> LayerMask {
        LayerMask(surface: sel, enabled: true, linked: true, density: 1, feather: 0)
    }

    /// Appends a smart filter (from a `filter.*` command) and re-renders. A selection becomes the
    /// filter mask, as in Photoshop. Without a renderable source the filter is applied to the
    /// cached pixels (and still recorded) (photocraft `add_smart_filter`).
    static func addSmartFilter(_ doc: inout Document, _ id: LayerId, _ sf: SmartFilter, selection: Surface?, services: EngineServices? = nil) throws {
        let canvas = doc.bounds
        let svc = services ?? decodeOnly
        let renderable = sourceBytes(doc.metadata, try smart(doc, id).source, fs: svc.fileSystem) != nil
        if renderable {
            try updateSmart(&doc, id) { sm in
                if let sel = selection, sm.filterMask == nil { sm.filterMask = maskFromSelection(sel) }
                sm.smartFilters.append(sf)
            }
            try refreshOrFail(&doc, id, services: services)
            return
        }
        let bounds = selection.map(\.contentBounds).flatMap { $0.isEmpty ? nil : $0 } ?? canvas
        guard let cache = try smart(doc, id).cache else { throw other("smart object has no pixels") }
        guard let out = FilterCommands.applyFilterToSurface(sf.command, sf.params, cache, bounds: bounds, selection: selection, canvas: canvas,
                                                            fs: services?.fileSystem) else {
            throw other("unknown filter \(sf.command)")
        }
        try updateSmart(&doc, id) { sm in
            sm.cache = out
            sm.smartFilters.append(sf)
        }
    }

    // MARK: Moving layers by whole pixels

    /// Moves a smart object by whole pixels without re-rendering (photocraft `shift_smart`).
    static func shiftSmart(_ sm: inout SmartObject, _ dx: Int32, _ dy: Int32) {
        TransformCommands.transformPlacement(&sm, .translate(Double(dx), Double(dy)))
        if let c = sm.cache { sm.cache = Resample.translateSurface(c, dx: dx, dy: dy) }
        if var m = sm.filterMask {
            m.surface = Resample.translateSurface(m.surface, dx: dx, dy: dy)
            sm.filterMask = m
        }
    }

    /// Moves a layer (any kind) by whole pixels without re-rendering anything (photocraft
    /// `shift_layer`).
    static func shiftLayer(_ l: inout Layer, _ dx: Int32, _ dy: Int32) {
        if dx == 0 && dy == 0 { return }
        let a = PCAffine.translate(Double(dx), Double(dy))
        func mv(_ s: Surface) -> Surface { Resample.translateSurface(s, dx: dx, dy: dy) }
        if var m = l.mask { m.surface = mv(m.surface); l.mask = m }
        if var vm = l.vectorMask { vm.path = vm.path.transform(a); l.vectorMask = vm }
        if var fc = l.fillCache { fc.surface = mv(fc.surface); l.fillCache = fc }
        switch l.content {
        case .raster: l.withRaster { $0 = mv($0) }
        case .text:
            l.withText { t in
                t.transform = a.mul(t.transform)
                if let c = t.cache { t.cache = mv(c) }
            }
        case .shape:
            l.withShape { sh in
                VectorCommands.transformShape(&sh, a)
                if let c = sh.cache { sh.cache = mv(c) }
            }
        case .smart: l.withSmartObject { shiftSmart(&$0, dx, dy) }
        case .group: l.withChildren { cs in for i in cs.indices { shiftLayer(&cs[i], dx, dy) } }
        case .adjustment, .fill: break
        }
    }

    // MARK: Conversion

    static func subtreeBounds(_ l: Layer, _ canvas: PixelRect) -> PixelRect {
        switch l.content {
        case .group(let g): return g.children.reduce(PixelRect.empty) { $0.union(subtreeBounds($1, canvas)) }
        case .adjustment, .fill: return canvas
        default: return l.surface?.contentBounds ?? .empty
        }
    }

    static func anyLayer(_ l: Layer, _ f: (Layer) -> Bool) -> Bool {
        f(l) || (l.children ?? []).contains { anyLayer($0, f) }
    }

    /// Builds the smart-object layer replacing `l` in `doc`: the layer (with its mask, effects and
    /// fill opacity) becomes a nested document cropped to its rendered bounds; visibility,
    /// opacity, blend mode, clipping and label stay on the smart layer. The cache is the exact
    /// composite, so the document looks the same before and after (photocraft `layer_to_smart`).
    static func layerToSmart(_ doc: Document, _ l: Layer, services: EngineServices? = nil) throws -> Layer {
        let background = doc.isBackground(l.id)
        var inner = l
        inner.visible = true
        inner.opacity = 1
        inner.clipped = false
        inner.locks = Locks()
        if !(inner.isGroup && inner.blend == .passThrough) { inner.blend = .normal }
        if background { inner.name = "Layer 0" }
        var out = try layersToSmart(doc, l.name, [inner], services: services)
        if background { out.name = "Layer 0" }
        out.visible = l.visible
        out.opacity = l.opacity
        out.blend = l.blend == .passThrough ? .normal : l.blend
        out.clipped = l.clipped
        out.label = l.label
        if !background { out.locks = l.locks }
        return out
    }

    /// Builds a smart-object layer named `name` whose nested document holds `layers` (bottom to
    /// top) at its top level, as Photoshop does when several layers are converted: no wrapper
    /// group. The nested document is cropped to the rendered bounds and the cache is the exact
    /// composite. The smart layer is visible, opaque and Normal (photocraft `layers_to_smart`).
    static func layersToSmart(_ doc: Document, _ name: String, _ layers: [Layer], services: EngineServices? = nil) throws -> Layer {
        let svc = services ?? decodeOnly
        let canvas = doc.bounds
        var sub = Document(name: "\(name).pcraft", size: doc.size, mode: doc.mode, depth: doc.depth)
        sub.resolutionDpi = doc.resolutionDpi
        sub.iccProfile = doc.iccProfile
        sub.globalLight = doc.globalLight
        // Pattern fills and pattern layer effects reference document-level patterns by id:
        // the embedded document keeps those resources.
        sub.patterns = doc.patterns
        if layers.contains(where: { anyLayer($0) { if case .smart = $0.content { true } else { false } } }) {
            // Nested PSD placed layers find their embedded files here.
            sub.metadata.psdGlobalBlocks = doc.metadata.psdGlobalBlocks
        }
        let hasFx = layers.contains { anyLayer($0) { $0.effects.enabled && !$0.effects.items.isEmpty } }
        let region = layers.map { subtreeBounds($0, canvas) }.reduce(canvas) { $0.union($1) }.outset(by: hasFx ? 256 : 0)
        sub.layers = layers

        let buf = try composite(sub, region, svc)
        let w = Swift.max(region.width, 1)
        var (x0, y0, x1, y1) = (Int32.max, Int32.max, Int32.min, Int32.min)
        for (i, p) in buf.px.enumerated() where p.w > 0 {
            let x = region.x0 + Int32(i % w), y = region.y0 + Int32(i / w)
            x0 = Swift.min(x0, x); y0 = Swift.min(y0, y); x1 = Swift.max(x1, x + 1); y1 = Swift.max(y1, y + 1)
        }
        guard x0 < x1, y0 < y1 else { throw other("the layer is empty, so there is nothing to convert") }
        let b = PixelRect(x0: x0, y0: y0, x1: x1, y1: y1)
        let fmt = doc.pixelFormat
        var cache = Resample.cropSurface(bufferToSurface(buf, fmt), keep: b)
        cache.prune()

        var shifted = sub.layers
        for i in shifted.indices { shiftLayer(&shifted[i], -b.x0, -b.y0) }
        sub.layers = shifted
        sub.size = PixelSize(width: b.width, height: b.height)
        let bytes = try encodeSource(sub)
        // Seed the decode cache with the composite we already have.
        cachePut(CacheKey(digest: digest(bytes), format: fmt),
                 SourceImage(surface: Resample.translateSurface(cache, dx: -b.x0, dy: -b.y0), bounds: sub.bounds))
        let source = SmartSource.embedded(fileName: sub.name, bytes: bytes)
        return Layer(name: name, content: .smart(SmartObject(source: source, transform: .translate(Double(b.x0), Double(b.y0)), cache: cache)))
    }
}

