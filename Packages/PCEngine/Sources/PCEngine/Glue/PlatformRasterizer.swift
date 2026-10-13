// Port of photocraft-compose's content rendering seam (crates/compose/src/lib.rs `render_content`, shape_split.rs; photocraft-vector `path_coverage`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// The glue only the engine may hold: PCRender asks a `LayerRasterizer` for the pixels it can't
// draw from stored rasters, and PCPlatform has the engines that can — CoreText for type
// (`TextEngine`) and CoreGraphics for shapes and vector masks (`VectorRasterizer`). Neither package
// depends on the other; the engine joins them here, so text and shape layers render.
//
// Smart objects without a cache render from their source through the same path as a refresh
// (`SmartCommands.render`: PCIO decodes the contents, PCAlgo places them and runs the smart
// filters), with no file access: embedded sources and PSD placed layers whose files the document
// holds render; a linked file on disk stays a reported miss.

import CoreGraphics
import Foundation
import PCDocument
import PCFoundation
import PCPlatform
import PCRender
import Synchronization

public final class PlatformRasterizer: LayerRasterizer, Sendable {
    /// Every request that came back empty (for diagnostics and tests).
    private let missLog = Mutex<[String]>([])

    public init() {}

    public func rasterize(_ layer: Layer, in document: Document) -> Surface? {
        let format = document.pixelFormat
        switch layer.content {
        case .text(let t):
            let r = TextEngine.rasterize(t, dpi: Double(document.resolutionDpi), format: format)
            return r.rect.isEmpty ? Surface(format: format) : r.surface
        case .shape(let s):
            return VectorRasterizer.rasterize(s, format: format, clip: document.bounds)
        case .smart(let so):
            if let s = smart(so, format: format, in: document) { return s }
            note("smart object \(layer.name)")
            return nil
        default:
            return nil
        }
    }

    public func coverage(of path: VectorPath, in rect: PixelRect) -> [Float]? {
        VectorRasterizer.fillCoverage(path, rect: rect)
    }

    public func renderShape(_ shape: ShapeLayer, format: PixelFormat, clip: PixelRect) -> Surface? {
        VectorRasterizer.rasterize(shape, format: format, clip: clip)
    }

    /// What the rasterizer couldn't render so far.
    public var misses: [String] { missLog.withLock { $0 } }

    private func note(_ m: String) { missLog.withLock { if $0.count < 256 { $0.append(m) } } }

    /// A smart object rendered from its embedded source through the refresh path (decoded once
    /// per contents and format, then cached by `SmartCommands`), in `document` (its metadata,
    /// canvas and pixel format; a canvas-less one in `format` without it).
    func smart(_ so: SmartObject, format: PixelFormat, in document: Document? = nil) -> Surface? {
        let doc = document ?? Document(name: "", size: PixelSize(width: 0, height: 0), mode: format.mode, depth: format.sample)
        guard let out = try? SmartCommands.render(doc, so) else { return nil }
        return out.format == format ? out : out.convertedAny(to: format)
    }
}
