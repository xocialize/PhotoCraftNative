// The default `DocumentCompositor`: PCRender's compositor (the port of photocraft-compose and
// photocraft-gpu), CPU reference or Metal. photocraft's io renders its PSD merged image and its
// previews with `photocraft_compose::{render_bands, flatten, thumbnail}`; this is that wiring.
// Port of photocraft-io's use of photocraft-compose (crates/io/src/psd_export.rs merged_planes,
// lib.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import PCDocument
import PCFoundation
import PCIOCore
import PCRender

/// `PCIOCore.DocumentCompositor` backed by PCRender. Text, shape and smart-object layers without a
/// cached raster go through `rasterizer` (the engine passes PCPlatform's; the default placeholder
/// records misses and draws them empty).
public final class RenderCompositor: PCIOCore.DocumentCompositor, @unchecked Sendable {
    public let compositor: PCRender.DocumentCompositor
    private let lock = NSLock()

    /// A process-wide default (`.automatic` backend, placeholder rasterizer), created on first use.
    public static let shared = RenderCompositor()

    /// A compositor on `backend` (`.automatic`: Metal when it can run the plan, else the CPU).
    public init(backend: PCRender.DocumentCompositor.Backend = .automatic, rasterizer: any LayerRasterizer = PlaceholderRasterizer()) {
        compositor = PCRender.DocumentCompositor(rasterizer: rasterizer, backend: backend)
    }

    /// Wraps an existing PCRender compositor (shares its caches and residency).
    public init(_ compositor: PCRender.DocumentCompositor) {
        self.compositor = compositor
    }

    /// The composite of `document` over `rect` in the document's pixel format (PCRender renders
    /// straight sRGB RGBA; it is converted with `PixelFormat.components(fromRGBA:)`, as
    /// photocraft's `from_rgba_into` does).
    public func composite(_ document: Document, rect: PixelRect) throws -> [Float] {
        let buf: RGBABuffer
        do {
            buf = try lock.withLock { try compositor.render(document, region: rect) }
        } catch {
            throw PCIOError.codec("composite failed: \(error)")
        }
        let fmt = document.pixelFormat
        let n = fmt.channels
        var out = [Float](repeating: 0, count: rect.area * n)
        guard buf.rect == rect, buf.px.count == rect.area else { throw PCIOError.codec("compositor returned \(buf.rect) for \(rect)") }
        for (i, p) in buf.px.enumerated() {
            let v = fmt.components(fromRGBA: p)
            for k in 0 ..< n { out[i * n + k] = v[k] }
        }
        return out
    }

    /// PCRender's own reduction for an RGB document, whose composite reads back as rendered (no
    /// round trip through the document's samples); the band-by-band default for the others.
    public func reduced(_ document: Document, width: Int, height: Int) throws -> [SIMD4<Float>] {
        guard document.pixelFormat.mode == .rgb else { return try ReducedComposite.reduce(document, width: width, height: height, compositor: self) }
        do {
            return try lock.withLock { try compositor.renderReduced(document, width: width, height: height) }.px
        } catch {
            throw PCIOError.codec("composite failed: \(error)")
        }
    }

    /// PCRender's bake of a filter adjustment layer (AB-D-0143, PCRender `FilterBake`).
    public func bakeFilterLayer(_ document: Document, layer: LayerId) throws -> Surface? {
        do {
            return try lock.withLock { try compositor.bakeFilterLayer(document, layer: layer) }
        } catch {
            throw PCIOError.codec("filter layer bake failed: \(error)")
        }
    }

    /// PCRender's reduction of only the damaged cells, for an RGB document (the default, which
    /// reduces the whole canvas, for the others).
    public func reduced(_ document: Document, width: Int, height: Int, damage: PixelRect) throws -> (rect: PixelRect, pixels: [SIMD4<Float>]) {
        guard document.pixelFormat.mode == .rgb else {
            let rect = ReducedComposite.cells(meeting: damage, canvas: document.size, width: width, height: height)
            return rect.isEmpty ? (rect, []) : (rect, ReducedComposite.crop(try reduced(document, width: width, height: height), width: width, rect))
        }
        do {
            let b = try lock.withLock { try compositor.renderReduced(document, width: width, height: height, damage: damage) }
            return (b.rect, b.px)
        } catch {
            throw PCIOError.codec("composite failed: \(error)")
        }
    }
}
