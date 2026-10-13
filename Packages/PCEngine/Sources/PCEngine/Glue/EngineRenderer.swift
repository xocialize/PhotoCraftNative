// Port of photocraft-engine's use of photocraft-compose (`render`, `flatten_to_surface`, `composite_to_surface`, `thumbnail`) and of the compositor injection photocraft-io expects for export composites, MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// One place that composites documents for the engine: PCRender's `DocumentCompositor` (Metal with
// the CPU reference as fallback) wired to PCPlatform through `PlatformRasterizer`, so type, shape
// and vector-mask layers render. It serves the canvas (`render`), commands that need the merged
// image (Flatten, Merge, Stamp, Sample All Layers), exports (`composite(_:rect:)` has the shape of
// PCIO's `DocumentCompositor` protocol, so its conformance is one line when PCIO lands), and
// PCIntelligence's `Compositor` for its "Sample All Layers" sources.

import CoreGraphics
import Foundation
import PCDocument
import PCFoundation
import PCIntelligence
import PCPlatform
import PCRender

public final class EngineRenderer: Sendable {
    /// The process-wide renderer (one Metal device, one leaf cache).
    public static let shared = EngineRenderer()

    public let rasterizer: PlatformRasterizer
    public let compositor: DocumentCompositor
    /// PCRender's compositor is safe to share but not to run twice at once on one Metal queue.
    private let lock = NSLock()

    public init(backend: DocumentCompositor.Backend = .automatic, rasterizer: PlatformRasterizer = PlatformRasterizer()) {
        self.rasterizer = rasterizer
        compositor = DocumentCompositor(rasterizer: rasterizer, backend: backend)
    }

    /// Text blending gamma of type layers (Color Settings › Blend Text Colors Using Gamma;
    /// Photoshop's 1.45, 1 = off). Process-wide like photocraft's `psblend::set_text_gamma`: every
    /// session sharing this renderer sees it.
    public var textGamma: Float {
        get { lock.lock(); defer { lock.unlock() }; return compositor.options.textGamma }
        set { lock.lock(); defer { lock.unlock() }; compositor.options.textGamma = newValue }
    }

    /// The composite of `doc` over `region` (straight-alpha sRGB-encoded RGBA).
    public func render(_ doc: Document, region: PixelRect) throws -> RGBABuffer {
        lock.lock(); defer { lock.unlock() }
        do { return try compositor.render(doc, region: region) } catch { throw EngineError.other("compositing failed: \(error)") }
    }

    /// The composite with 32-bit float accumulation on the Metal path, for reads that must give a
    /// pixel's exact value (`document.pixel`, the Eyedropper, adjustment eyedroppers). PCRender's
    /// `.automatic` precision composites a plain 8-bit stack in half floats by design (0.5996 for
    /// 0.6, 0.1 of a level; PCRender PORT-NOTES "Parity"), which is right for display, not for
    /// sampling. Matches the CPU reference.
    public func renderExact(_ doc: Document, region: PixelRect) throws -> RGBABuffer {
        lock.lock(); defer { lock.unlock() }
        let metal = compositor.metal
        let saved = metal?.precision ?? .automatic
        metal?.precision = .float
        defer { metal?.precision = saved }
        do { return try compositor.render(doc, region: region) } catch { throw EngineError.other("compositing failed: \(error)") }
    }

    /// The CPU reference composite (the oracle tests compare against).
    public func renderCPU(_ doc: Document, region: PixelRect) throws -> RGBABuffer {
        lock.lock(); defer { lock.unlock() }
        do { return try compositor.renderCPU(doc, region: region) } catch { throw EngineError.other("compositing failed: \(error)") }
    }

    /// One composite pixel (photocraft `document.pixel`), at full precision (`renderExact`).
    public func pixel(_ doc: Document, x: Int32, y: Int32) throws -> SIMD4<Float> {
        let r = PixelRect(x0: x, y0: y, x1: x &+ 1, y1: y &+ 1)
        if r.isEmpty { return .zero }
        return try renderExact(doc, region: r).px.first ?? .zero
    }

    /// The composite over `rect` as a surface in `format`, flattened over `background` when given
    /// (photocraft `composite_to_surface` / `flatten_to_surface`).
    public func compositeToSurface(_ doc: Document, rect: PixelRect? = nil, format: PixelFormat, background: SIMD3<Float>? = nil) throws -> Surface {
        lock.lock(); defer { lock.unlock() }
        do { return try compositor.compositeToSurface(doc, rect: rect, format: format, background: background) } catch {
            throw EngineError.other("compositing failed: \(error)")
        }
    }

    /// The merged image of `rect` as interleaved normalised samples in `document.pixelFormat`,
    /// straight alpha — the shape of PCIO's `DocumentCompositor.composite(_:rect:)` (the export
    /// composite).
    public func composite(_ document: Document, rect: PixelRect) throws -> [Float] {
        let fmt = document.pixelFormat
        let buf = try render(document, region: rect)
        var out: [Float] = []
        out.reserveCapacity(buf.px.count * fmt.channels)
        for p in buf.px { out += fmt.components(fromRGBA: p) }
        return out
    }

    /// A reduced composite at most `maxSide` on its longer side.
    public func thumbnail(_ doc: Document, maxSide: Int) throws -> RGBABuffer {
        lock.lock(); defer { lock.unlock() }
        do { return try compositor.thumbnail(doc, maxSide: maxSide) } catch { throw EngineError.other("compositing failed: \(error)") }
    }

    /// The composite (reduced to `maxSide`, 0 = full size) as PNG bytes.
    public func png(_ doc: Document, maxSide: Int) throws -> Data {
        let buf = maxSide > 0 ? try thumbnail(doc, maxSide: maxSide) : try render(doc, region: doc.bounds)
        return try EngineRenderer.pngData(buf)
    }

    /// Encodes an RGBA buffer as an 8-bit PNG.
    public static func pngData(_ buf: RGBABuffer) throws -> Data {
        let w = buf.rect.width, h = buf.rect.height
        guard w > 0, h > 0 else { throw EngineError.other("nothing to encode") }
        var floats = [Float](repeating: 0, count: w * h * 4)
        for (i, p) in buf.px.enumerated() { floats[i * 4] = p.x; floats[i * 4 + 1] = p.y; floats[i * 4 + 2] = p.z; floats[i * 4 + 3] = p.w }
        let raster = RasterBuffer(width: w, height: h, format: .rgba32f, floats: floats).converted(to: .u8)
        do { return try ImageCodecs.encode(raster, as: .png) } catch { throw EngineError.other("PNG encode failed: \(error)") }
    }

    /// PCIntelligence's composite source ("Sample All Layers"): the visible composite of `rect`
    /// in document space, in the document's pixel format.
    public var intelligenceCompositor: Compositor {
        { [self] doc, rect in try self.compositeToSurface(doc, rect: rect, format: doc.pixelFormat) }
    }

    /// Drops every render cache (Edit › Purge › All).
    public func purge() {
        lock.lock(); defer { lock.unlock() }
        compositor.purge()
    }
}
