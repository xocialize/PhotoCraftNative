// Port of photocraft-compose (crates/compose/src/lib.rs `render`, `render_bands`, `band_rows_for`, `composite_to_surface`, `flatten`, `render_reduced*`, `thumbnail*`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// The document-level entry point: plan a PCDocument over a region and run the plan on the GPU
// (Metal) or the CPU reference, with the CPU as the fallback for what the GPU can't do. Big renders
// stream in bands (whole 256-row tiles) so peak memory is one band; reductions (thumbnails,
// navigators, reduced canvas textures) area-average premultiplied colour band by band; the
// composite can be written back to a Surface in any pixel format. The PSD composite oracle hook
// (`CompositeOracle`) compares a document's composite with Photoshop's.

import Foundation
import Metal
import PCDocument
import PCFoundation
import simd

public final class DocumentCompositor: @unchecked Sendable {
    public enum Backend: Sendable { case automatic, cpu, metal }

    public let rasterizer: any LayerRasterizer
    public let cache: DocumentLeafCache
    public let cpu: CPUCompositor
    /// nil when Metal is unavailable.
    public let metal: MetalCompositor?
    public var backend: Backend
    public var options: PlanOptions
    /// Rows per band of `renderBands` when the caller passes 0 (≈ `bandPixels` per band).
    public static let bandPixels = 8 << 20
    /// Keeps the CPU caches registered with `MemoryPressureRelay.shared` (they trim once a host
    /// starts it).
    private let pressure: MemoryPressureRegistration
    /// Side of the CPU reference's render tiles (bands are whole multiples of it).
    public static let renderTile: Int32 = 256

    public init(rasterizer: any LayerRasterizer = PlaceholderRasterizer(), backend: Backend = .automatic,
                cpu: CPUCompositor = CPUCompositor(), metal: MetalCompositor? = try? MetalCompositor(),
                cache: DocumentLeafCache = DocumentLeafCache(), options: PlanOptions = PlanOptions()) {
        self.rasterizer = rasterizer; self.backend = backend; self.cpu = cpu; self.metal = metal; self.cache = cache; self.options = options
        pressure = MemoryPressureRelay.shared.register("PCRender CPU caches") { level in cpu.trim(level) + cache.trim(level) }
    }

    /// Drops every cache (Edit › Purge › All).
    public func purge() {
        cache.purge(); cpu.purge(); metal?.purge()
    }

    /// Trims the CPU caches (CPUCompositor's maps and masks, the leaf cache) for memory pressure;
    /// returns the bytes freed. The GPU caches shrink through `MetalCompositor.relieve` instead.
    @discardableResult
    public func trimCPUCaches(_ level: MemoryPressureRelay.Level) -> Int { cpu.trim(level) + cache.trim(level) }

    /// The GPU transient of one export or flatten band of a `width`-wide document (raise the canvas's
    /// declaration by it while a band pass runs); 0 without Metal.
    public func bandTransient(width: Int) -> Int {
        guard let metal, width > 0 else { return 0 }
        let rows = Int(DocumentCompositor.bandRows(width: width, requested: 0))
        return metal.transientEstimate(region: PixelRect(x: 0, y: 0, width: width, height: rows), outputFormat: .rgba32Float)
    }

    /// Plans `doc` over `region`.
    public func plan(_ doc: Document, region: PixelRect) -> DocumentPlan {
        DocumentPlanner.build(document: doc, region: region, rasterizer: rasterizer, cache: cache, subRenderer: cpu, options: options)
    }

    /// The backend a render of `plan` uses (`.cpu` when the GPU is unavailable or can't run it).
    public func backend(for plan: RenderPlan) -> Backend {
        switch backend {
        case .cpu: return .cpu
        case .metal, .automatic:
            guard let metal, metal.unsupportedReason(plan) == nil else { return .cpu }
            return .metal
        }
    }

    /// The composite of `doc` over `region` (straight-alpha RGBA).
    public func render(_ doc: Document, region: PixelRect) throws -> RGBABuffer {
        if region.isEmpty { return RGBABuffer(transparent: region) }
        let p = plan(doc, region: region)
        return try run(p)
    }

    /// Runs a planned render on the chosen backend (straight RGBA for display).
    public func run(_ p: DocumentPlan) throws -> RGBABuffer {
        try display(try runNative(p, backend: backend), p)
    }

    /// What a plan renders before display conversion: the plan's own buffer, and the black plane's
    /// for a CMYK document.
    public struct NativeResult: Sendable {
        public var native: NativeSpace
        public var buffer: RGBABuffer
        public var black: RGBABuffer?
    }

    /// Runs `p` (and its black plane) on `backend`, the results in the plan's own space.
    public func runNative(_ p: DocumentPlan, backend: Backend) throws -> NativeResult {
        func one(_ plan: RenderPlan, _ source: DocumentRenderSource) throws -> RGBABuffer {
            if backend != .cpu, let metal, metal.unsupportedReason(plan) == nil {
                do { return try metal.renderBuffer(plan, region: p.region, source: source) } catch MetalCompositorError.unsupported {
                    // Fall through to the CPU.
                }
            }
            return try cpu.render(plan, region: p.region, source: source)
        }
        let a = try one(p.plan, p.source)
        let k = try p.black.map { try one($0.plan, $0.source) }
        return NativeResult(native: p.native, buffer: a, black: k)
    }

    /// A native result as display RGBA (Lab and CMYK converted as `Surface.readRGBA` converts),
    /// after rounding its channels to the document depth: a Lab or CMYK composite exists only at
    /// that depth (Photoshop's merged image), and half a level of a saturated Lab colour is
    /// several display levels.
    func display(_ r: NativeResult, _ p: DocumentPlan) throws -> RGBABuffer {
        let q = adjustmentQuantum(p.plan.context.depth)
        switch r.native {
        case .lab: return NativeConvert.labToRGB(NativeConvert.quantized(r.buffer, q))
        case .cmykInk, .cmykBlack:
            return NativeConvert.cmykToRGB(NativeConvert.quantized(r.buffer, q), NativeConvert.quantized(r.black ?? r.buffer, q))
        case .none: return r.buffer
        }
    }

    /// The composite flattened over an opaque `background` (display RGB), matted in the
    /// document's own model as Photoshop's merged image is: white paper carries no ink in CMYK,
    /// and Lab mixes with the background's Lab channels.
    public func renderFlattened(_ doc: Document, region: PixelRect, over background: SIMD3<Float>, backend: Backend? = nil) throws -> RGBABuffer {
        let p = plan(doc, region: region)
        var r = try runNative(p, backend: backend ?? self.backend)
        let q = adjustmentQuantum(p.plan.context.depth)
        r.buffer = NativeConvert.quantized(r.buffer, q)
        r.black = r.black.map { NativeConvert.quantized($0, q) }
        switch r.native {
        case .lab:
            let bg = AdjustMath.labNorm(background)
            var b = r.buffer
            for i in b.px.indices {
                let v = b.px[i], a = min(max(v.w, 0), 1)
                b.px[i] = SIMD4(SIMD3(v.x, v.y, v.z) * a + bg * (1 - a), 1)
            }
            return NativeConvert.labToRGB(NativeConvert.quantized(b, q))
        case .cmykInk, .cmykBlack:
            if background == SIMD3(repeating: 1) { return NativeConvert.cmykToRGB(r.buffer, r.black ?? r.buffer, paper: true) }
            return try display(r, p).over(background: background)
        case .none:
            return r.buffer.over(background: background)
        }
    }

    /// The CPU reference composite.
    public func renderCPU(_ doc: Document, region: PixelRect) throws -> RGBABuffer {
        let p = plan(doc, region: region)
        return try display(try runNative(p, backend: .cpu), p)
    }

    /// The GPU composite as a texture (display, export without a read-back). Lab and CMYK
    /// documents composite natively on the GPU and are converted for display on the CPU.
    public func renderMetal(_ doc: Document, region: PixelRect, outputFormat: MTLPixelFormat = .rgba32Float,
                            outputStorage: MTLStorageMode = .private) throws -> MetalRenderResult {
        guard let metal else { throw MetalCompositorError.noMetal }
        let p = plan(doc, region: region)
        if p.native == .none {
            return try metal.render(p.plan, region: region, source: p.source, outputFormat: outputFormat, outputStorage: outputStorage)
        }
        let out = try display(try runNative(p, backend: .metal), p)
        guard let tex = metal.context.makeTexture(width: region.width, height: region.height, pixelFormat: .rgba32Float,
                                                   usage: [.shaderRead, .shaderWrite], storage: .shared) else {
            throw MetalCompositorError.gpu("output texture \(region)")
        }
        out.px.withUnsafeBytes { tex.replace(region: MTLRegionMake2D(0, 0, region.width, region.height), mipmapLevel: 0, withBytes: $0.baseAddress!,
                                             bytesPerRow: region.width * 16) }
        return MetalRenderResult(texture: tex, rect: region, gpuTime: 0, cells: 0)
    }

    /// The whole canvas.
    public func flatten(_ doc: Document) throws -> RGBABuffer { try render(doc, region: doc.bounds) }

    // MARK: Levels of detail

    /// The composite of `doc` over `region` at level of detail `level` (LevelOfDetail.swift): the
    /// plan of `region` composited over the level pixels covering it from reduced sources, straight
    /// RGBA with its rect in level pixels. An approximation of `renderReduced` at 2^-level for
    /// ~4^-level of the work; PORT-NOTES.md states the parity. Lab and CMYK documents composite in
    /// their own model and are converted for display, as `render` converts them.
    public func render(_ doc: Document, region: PixelRect, level: Int, backend: Backend? = nil) throws -> RGBABuffer {
        let l = LevelOfDetail.clamp(level)
        if l == 0 { return try render(doc, region: region) }
        if region.isEmpty { return RGBABuffer(transparent: .empty) }
        let p = plan(doc, region: region)
        return try display(try runNative(p, backend: backend ?? self.backend, level: l), p)
    }

    /// `render(_:region:level:)` on the GPU as a texture (level pixels from (0, 0)). Lab and CMYK
    /// documents composite natively on the GPU and are converted for display on the CPU.
    public func renderMetal(_ doc: Document, region: PixelRect, level: Int, outputFormat: MTLPixelFormat = .rgba32Float,
                            outputStorage: MTLStorageMode = .private) throws -> MetalRenderResult {
        guard let metal else { throw MetalCompositorError.noMetal }
        let p = plan(doc, region: region)
        if p.native == .none {
            return try metal.render(p.plan, region: region, level: level, source: p.source, outputFormat: outputFormat, outputStorage: outputStorage)
        }
        let out = try display(try runNative(p, backend: .metal, level: LevelOfDetail.clamp(level)), p)
        let r = out.rect
        guard let tex = metal.context.makeTexture(width: r.width, height: r.height, pixelFormat: .rgba32Float,
                                                   usage: [.shaderRead, .shaderWrite], storage: .shared) else {
            throw MetalCompositorError.gpu("output texture \(r)")
        }
        out.px.withUnsafeBytes { tex.replace(region: MTLRegionMake2D(0, 0, r.width, r.height), mipmapLevel: 0, withBytes: $0.baseAddress!,
                                             bytesPerRow: r.width * 16) }
        return MetalRenderResult(texture: tex, rect: r, gpuTime: 0, cells: 0)
    }

    /// `runNative` at a level of detail.
    func runNative(_ p: DocumentPlan, backend: Backend, level: Int) throws -> NativeResult {
        if level == 0 { return try runNative(p, backend: backend) }
        func one(_ plan: RenderPlan, _ source: DocumentRenderSource) throws -> RGBABuffer {
            if backend != .cpu, let metal, metal.unsupportedReason(plan) == nil {
                do { return try metal.renderBuffer(plan, region: p.region, level: level, source: source) } catch MetalCompositorError.unsupported {
                    // Fall through to the CPU.
                }
            }
            return try cpu.render(plan, region: p.region, level: level, source: source)
        }
        let a = try one(p.plan, p.source)
        let k = try p.black.map { try one($0.plan, $0.source) }
        return NativeResult(native: p.native, buffer: a, black: k)
    }

    /// `band_rows_for`: `requested` rounded up to whole render tiles, or ≈ `bandPixels` per band.
    public static func bandRows(width: Int, requested: Int32) -> Int32 {
        let want = requested > 0 ? Int64(requested) : Int64(bandPixels / max(width, 1))
        let t = Int64(renderTile)
        let tiles = (want + t - 1) / t
        return Int32(min(max(tiles, 1), 1 << 16) * t)
    }

    /// `render_bands`: `rect` in horizontal bands, top to bottom, each handed to `sink`.
    public func renderBands(_ doc: Document, rect: PixelRect, bandRows: Int32 = 0, _ sink: (RGBABuffer) throws -> Void) throws {
        if rect.isEmpty { return }
        let rows = DocumentCompositor.bandRows(width: rect.width, requested: bandRows)
        var y = rect.y0
        while y < rect.y1 {
            let y1 = Int32(clamping: min(Int64(y) + Int64(rows), Int64(rect.y1)))
            try sink(try render(doc, region: PixelRect(x0: rect.x0, y0: y, x1: rect.x1, y1: y1)))
            y = y1
        }
    }

    /// `composite_to_surface`: the composite over `rect` in `format` (optionally flattened over an
    /// opaque `background`), written band by band; transparent pixels are left at the default.
    public func compositeToSurface(_ doc: Document, rect: PixelRect? = nil, format: PixelFormat, background: SIMD3<Float>? = nil) throws -> Surface {
        var s = Surface(format: format)
        let empty = s.defaultPixelValue
        let n = format.channels
        // A Lab / CMYK composite written into its own model keeps its channels (no RGB round trip:
        // photocraft's `native::flatten_cmyk`, for every layer kind).
        if background == nil || (format.mode == .cmyk && background == SIMD3(repeating: 1)),
           DocumentPlanner.nativeSpace(doc, options).mode == format.mode, format.mode == doc.mode {
            let paper = background != nil
            var y = (rect ?? doc.bounds).y0
            let r = rect ?? doc.bounds
            let rows = DocumentCompositor.bandRows(width: r.width, requested: 0)
            while y < r.y1 {
                let band = PixelRect(x0: r.x0, y0: y, x1: r.x1, y1: Int32(clamping: min(Int64(y) + Int64(rows), Int64(r.y1))))
                let p = plan(doc, region: band)
                let res = try runNative(p, backend: backend)
                var data = [Float](repeating: 0, count: band.area * n)
                let inks = res.native == .lab ? [] : NativeConvert.inks(res.buffer, res.black ?? res.buffer, paper: paper)
                for i in 0..<band.area {
                    let q = res.buffer.px[i]
                    let a: Float = paper ? 1 : q.w
                    let v: [Float]
                    if format.alpha && (a <= 0 || a.isNaN) && empty.count == n {
                        v = empty
                    } else if res.native == .lab {
                        v = [q.x, q.y, q.z] + (format.alpha ? [a] : [])
                    } else {
                        let c = simd_clamp(inks[i], .zero, SIMD4(repeating: 1))
                        v = [c.x, c.y, c.z, c.w] + (format.alpha ? [a] : [])
                    }
                    for k in 0..<n { data[i * n + k] = v[k] }
                }
                s.writeRegion(band, data)
                y = band.y1
            }
            s.prune()
            return s
        }
        try renderBands(doc, rect: rect ?? doc.bounds) { band in
            let b = background.map { band.over(background: $0) } ?? band
            var data = [Float](repeating: 0, count: b.px.count * n)
            for (i, p) in b.px.enumerated() {
                let v = format.alpha && (p.w <= 0 || p.w.isNaN) && empty.count == n ? empty : format.components(fromRGBA: p)
                for k in 0..<n { data[i * n + k] = v[k] }
            }
            s.writeRegion(b.rect, data)
        }
        s.prune()
        return s
    }

    // MARK: Reductions

    /// `render_reduced_rect` / `render_reduced_damage`: the composite of `rect` (default: the
    /// canvas; it may lie past the canvas) area-averaged (premultiplied) to `width` × `height`
    /// (clamped to the source size). With `damage`, only the output pixels whose source areas meet
    /// it, with the same values the whole reduction gives them. The result's rect is in output
    /// pixels from (0, 0) (empty when `damage` misses `rect`).
    public func renderReduced(_ doc: Document, rect: PixelRect? = nil, width: Int, height: Int, damage: PixelRect? = nil,
                              bandRows: Int32 = 0) throws -> RGBABuffer {
        let b = rect ?? doc.bounds
        let (fw, fh) = (b.width, b.height)
        let w = min(max(width, 1), max(fw, 1)), h = min(max(height, 1), max(fh, 1))
        let full = PixelRect(x: 0, y: 0, width: w, height: h)
        if fw == 0 || fh == 0 { return RGBABuffer(transparent: damage != nil ? .empty : full) }
        @Sendable func span(_ t: Int, _ f: Int, _ n: Int) -> (Int, Int) { (t * f / n, min(max((t + 1) * f / n, t * f / n + 1), f)) }
        func cell(_ x: Int, _ f: Int, _ n: Int) -> Int { max((x + 1) * n - 1, 0) / f }
        var out = full
        if let dmg = damage {
            let d = dmg.intersect(b)
            if d.isEmpty { return RGBABuffer(transparent: .empty) }
            let (x0, x1) = (Int(d.x0 - b.x0), Int(d.x1 - b.x0)), (y0, y1) = (Int(d.y0 - b.y0), Int(d.y1 - b.y0))
            out = PixelRect(x0: Int32(cell(x0, fw, w)), y0: Int32(cell(y0, fh, h)), x1: Int32(cell(x1 - 1, fw, w) + 1), y1: Int32(cell(y1 - 1, fh, h) + 1))
        }
        let (ox0, oy0, ow, oh) = (Int(out.x0), Int(out.y0), out.width, out.height)
        let (sx0, sx1) = (span(ox0, fw, w).0, span(ox0 + ow - 1, fw, w).1)
        let (sy0, sy1) = (span(oy0, fh, h).0, span(oy0 + oh - 1, fh, h).1)
        let src = PixelRect(x0: b.x0 + Int32(sx0), y0: b.y0 + Int32(sy0), x1: b.x0 + Int32(sx1), y1: b.y0 + Int32(sy1))
        if w == fw && h == fh {
            var px = try render(doc, region: src)
            px.rect = out
            return px
        }
        func map(_ f: Int, _ n: Int) -> [Int] {
            var m = [Int](repeating: 0, count: f)
            for t in 0..<n { let (a, z) = span(t, f, n); for i in a..<z { m[i] = t } }
            return m
        }
        let cols = Array(map(fw, w)[sx0..<sx1]), rows = map(fh, h)
        var acc = [SIMD4<Float>](repeating: .zero, count: ow * oh)
        try renderBands(doc, rect: src, bandRows: bandRows) { band in
            let (by0, by1) = (Int(band.rect.y0 - b.y0), Int(band.rect.y1 - b.y0))
            let (t0, t1) = (rows[by0], rows[by1 - 1] + 1)
            let sw = sx1 - sx0
            acc.withUnsafeMutableBufferPointer { ap in
                let A = UnsafeSendable(ap)
                DispatchQueue.concurrentPerform(iterations: t1 - t0) { k in
                    let t = t0 + k
                    let (a, z) = span(t, fh, h)
                    for y in max(a, by0)..<min(z, by1) {
                        let row = (y - by0) * sw
                        for (i, c) in cols.enumerated() {
                            let p = band.px[row + i]
                            let o = (t - oy0) * ow + c - ox0
                            A.value[o] += SIMD4(p.x * p.w, p.y * p.w, p.z * p.w, p.w)
                        }
                    }
                }
            }
        }
        for i in acc.indices {
            let (x0, x1) = span(ox0 + i % ow, fw, w), (y0, y1) = span(oy0 + i / ow, fh, h)
            let n = Float(max((y1 - y0) * (x1 - x0), 1))
            let p = acc[i]
            acc[i] = p.w > 0 ? SIMD4(p.x / p.w, p.y / p.w, p.z / p.w, p.w / n) : .zero
        }
        return RGBABuffer(rect: out, px: acc)
    }

    /// `thumbnail_size`: at most `maxSide` on the longer side, aspect kept.
    public static func thumbnailSize(_ doc: Document, maxSide: Int) -> (width: Int, height: Int) {
        let b = doc.bounds
        let longest = max(b.width, b.height, 1)
        let scale = min(Float(maxSide) / Float(longest), 1)
        return (max(Int((Float(b.width) * scale).rounded()), 1), max(Int((Float(b.height) * scale).rounded()), 1))
    }

    /// `thumbnail_buffer` (exact reduction; photocraft's proxy documents for > 16 MP are not ported).
    public func thumbnail(_ doc: Document, maxSide: Int) throws -> RGBABuffer {
        let (w, h) = DocumentCompositor.thumbnailSize(doc, maxSide: maxSide)
        return try renderReduced(doc, width: w, height: h)
    }
}

// MARK: - PSD composite oracle hook

/// One document with a reference composite to compare against: Photoshop's own composite of the
/// file (the PSD "merged image data", i.e. Image Data section), as PCPSD will decode it.
public struct OracleCase: Sendable {
    public var name: String
    public var document: Document
    /// Straight-alpha RGBA, sRGB-encoded 0…1 floats (CMYK / Lab / Grayscale files converted the
    /// way `Surface.readRGBA` converts), covering exactly `document.bounds`. A merged image without
    /// transparency is opaque (alpha 1).
    public var reference: RGBABuffer
    /// The reference shows the composite flattened over white (Photoshop writes the merged image of
    /// a file without "Maximize compatibility" transparency that way): compare against our
    /// composite over this colour.
    public var flattenedOver: SIMD3<Float>?
    public init(name: String, document: Document, reference: RGBABuffer, flattenedOver: SIMD3<Float>? = nil) {
        self.name = name; self.document = document; self.reference = reference; self.flattenedOver = flattenedOver
    }
}

/// How a composite differs from its reference (premultiplied RGBA, in 8-bit levels).
public struct OracleComparison: Sendable, CustomStringConvertible {
    public var name: String
    public var backend: DocumentCompositor.Backend
    public var pixels: Int
    /// Largest absolute difference of any premultiplied channel, in levels (0…255).
    public var maxLevels: Float
    /// Mean absolute difference over all channels, in levels.
    public var meanLevels: Float
    /// Pixels with a channel off by more than `toleranceLevels`.
    public var pixelsOff: Int
    public var toleranceLevels: Float
    public var fractionOff: Double { pixels == 0 ? 0 : Double(pixelsOff) / Double(pixels) }
    /// What the rasterizer could not supply (those layers drew as empty).
    public var misses: [RasterMiss]
    public var description: String {
        String(format: "%@ [%@]: max %.1f, mean %.3f levels, %.2f%% of %d px over %.0f", name, "\(backend)", maxLevels, meanLevels,
               fractionOff * 100, pixels, toleranceLevels) + (misses.isEmpty ? "" : " (\(misses.count) rasterizer misses)")
    }
}

/// The PSD composite-oracle hook. PCPSD (or a test that links it) registers a loader turning a
/// file into an `OracleCase`; `PSDOracleTests` then walks `PCRENDER_PSD_CORPUS` (a directory of
/// .psd / .psb files) and compares every file's composite, on the CPU and on Metal, with the
/// reference. Without a loader or the variable the test is skipped.
public enum CompositeOracle {
    public typealias Loader = @Sendable (URL) throws -> OracleCase?
    nonisolated(unsafe) private static var registered: Loader?
    private static let lock = NSLock()

    /// Installs the loader (nil removes it). It returns nil for files it doesn't handle.
    public static func register(loader: Loader?) {
        lock.lock(); registered = loader; lock.unlock()
    }

    public static var loader: Loader? {
        lock.lock(); defer { lock.unlock() }
        return registered
    }

    /// The corpus directory (`PCRENDER_PSD_CORPUS`), when set and present.
    public static var corpusDirectory: URL? {
        guard let p = ProcessInfo.processInfo.environment["PCRENDER_PSD_CORPUS"], !p.isEmpty else { return nil }
        var dir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: p, isDirectory: &dir), dir.boolValue else { return nil }
        return URL(fileURLWithPath: p)
    }

    /// The .psd / .psb files under `dir`, sorted.
    public static func corpusFiles(_ dir: URL) -> [URL] {
        let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
        var out: [URL] = []
        while let u = e?.nextObject() as? URL {
            if ["psd", "psb"].contains(u.pathExtension.lowercased()) { out.append(u) }
        }
        return out.sorted { $0.path < $1.path }
    }

    /// Composites `c.document` with `compositor` on `backend` and compares it with the reference.
    public static func compare(_ c: OracleCase, compositor: DocumentCompositor, backend: DocumentCompositor.Backend = .cpu,
                               toleranceLevels: Float = 2) throws -> OracleComparison {
        let saved = compositor.backend
        compositor.backend = backend
        defer { compositor.backend = saved }
        let p = compositor.plan(c.document, region: c.document.bounds)
        let got = try c.flattenedOver.map { try compositor.renderFlattened(c.document, region: c.document.bounds, over: $0) } ?? compositor.run(p)
        precondition(got.rect == c.reference.rect, "oracle reference must cover the document bounds")
        var maxD: Float = 0, sum: Double = 0, off = 0
        for i in got.px.indices {
            let a = got.px[i], b = c.reference.px[i]
            let pa = SIMD4(a.x * a.w, a.y * a.w, a.z * a.w, a.w), pb = SIMD4(b.x * b.w, b.y * b.w, b.z * b.w, b.w)
            var d = (pa - pb) * 255
            for k in 0..<4 { d[k] = d[k].isNaN ? 255 : Swift.abs(d[k]) }
            let m = d.max()
            maxD = max(maxD, m)
            sum += Double(d.sum())
            if m > toleranceLevels { off += 1 }
        }
        let n = got.px.count
        return OracleComparison(name: c.name, backend: backend, pixels: n, maxLevels: maxD, meanLevels: n == 0 ? 0 : Float(sum / Double(n * 4)),
                                pixelsOff: off, toleranceLevels: toleranceLevels, misses: p.misses)
    }
}
