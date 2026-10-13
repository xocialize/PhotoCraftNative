// Port of photocraft-io (crates/io/src/affinity.rs; the preview's one-layer document from flat.rs
// `image_to_document`; type-layer preparation from text_import.rs `prepare`), MIT OR Apache-2.0,
// © ArtCraft Team and the PhotoCraft contributors.
//
// Affinity documents (`.af`, `.afdesign`, `.afphoto`, `.afpub`): the native layers, curves, shapes,
// artboards, text, images and masks PCAffinity reads, mapped to PhotoCraft layers (groups, shape
// layers, type layers, embedded smart objects, pixel layers, layer and vector masks). What could not
// be mapped is listed in the warnings. A file whose native data can't be read opens as its embedded
// preview, with a warning saying why. Affinity files are never written back (`sourceReadOnly`).
//
// Rendering stays outside, as in photocraft's io/compose split: shape and type pixels come from an
// injected `LayerContentRenderer` (photocraft's `photocraft_vector::render_shape` and
// `text_import::prepare`); without one their caches stay nil. Embedded images and the preview PNG
// are decoded by the injected `FlatImageCodec`.

import CoreGraphics
import Foundation
import ImageIO
import PCAffinity
import PCDocument
import PCFoundation
import PCIOCore

public enum AffinityImport {
    /// Extensions recognized as Affinity documents.
    public static let extensions: [String] = ["af", "afphoto", "afdesign", "afpub"]

    /// Pixels an image or mask is resampled into, after cropping to the canvas.
    static let maxPixels: UInt64 = 64 << 20
    /// Canvas side in pixels.
    static let maxSide: Double = 300_000
    /// Largest type raster the import draws on its own (photocraft `text_import::MAX_RENDER_PIXELS`):
    /// the sizes and frames come from an untrusted file.
    static let maxTextPixels: UInt64 = 64 * 1024 * 1024
    /// photocraft decodes the preview within 4096 px a side (`photocraft_codecs::Limits`).
    static let maxPreviewSide = 4096
    /// photocraft decodes embedded images within 65 535 px a side and `maxPixels`.
    static let maxEmbeddedSide = 65_535

    /// `true` when `bytes` start with the Affinity container magic (photocraft `is_affinity`).
    public static func isAffinity(_ bytes: [UInt8]) -> Bool {
        Affinity.isAffinity(bytes)
    }

    /// `true` when the last path component of `name` (split at `/` and `\`) ends in one of
    /// `extensions`, ignoring ASCII case.
    public static func hasExtension(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        let start = bytes.lastIndex { $0 == 0x2F || $0 == 0x5C }.map { $0 + 1 } ?? 0
        let base = bytes[start...]
        guard let dot = base.lastIndex(of: 0x2E) else { return false }
        let ext = base[(dot + 1)...].map { (0x41...0x5A).contains($0) ? $0 | 0x20 : $0 }
        return extensions.contains { Array($0.utf8) == ext }
    }

    /// Imports an Affinity document: the native model when PCAffinity can read it, else its
    /// embedded preview as a one-layer document (`previewOnly`), with the reason first among the
    /// warnings. Either way the result is `sourceReadOnly`: Save never writes back over the
    /// Affinity file.
    public static func importDocument(name: String, bytes: [UInt8], renderer: (any LayerContentRenderer)?,
                                      codec: any FlatImageCodec) throws -> ImportResult {
        let d: Affinity.Document
        do {
            d = try Affinity.read(bytes, limits: .default)
        } catch {
            return try preview(name, bytes, error, codec)
        }
        let b = try AffinityBuilder(name, d, renderer: renderer, codec: codec)
        b.document(d)
        var warnings = d.warnings.map { "Affinity: not imported or approximated: \($0)." }
        warnings += b.warnings.map { "Affinity: \($0)." }
        // Type layers were drawn from their model as they were made (`prepareText`).
        // Save never writes back over the Affinity file.
        return ImportResult(document: b.doc, warnings: warnings, sourceReadOnly: true, previewOnly: false)
    }

    // MARK: - Preview fallback

    /// The embedded preview, for files whose native document can't be read.
    static func preview(_ name: String, _ bytes: [UInt8], _ native: AffinityError, _ codec: any FlatImageCodec) throws -> ImportResult {
        let p: Affinity.Preview
        do {
            p = try Affinity.preview(bytes)
        } catch {
            throw PCIOError.unsupported("\(native); its embedded preview can't be read either (\(error))")
        }
        let img: DecodedImage
        do {
            img = try codec.decode(p.png)
        } catch let e as PCIOError {
            throw e
        } catch {
            throw PCIOError.codec("\(error)")
        }
        guard img.width > 0, img.height > 0, img.width <= maxPreviewSide, img.height <= maxPreviewSide else {
            throw PCIOError.limitExceeded("the Affinity preview is larger than \(maxPreviewSide) pixels on a side")
        }
        var r = imageToDocument(name, img)
        if !r.document.layers.isEmpty {
            r.document.layers[0].name = "Affinity preview"
            r.document.layers[0].locks = Locks()
        }
        r.sourceReadOnly = true
        r.previewOnly = true
        r.warnings.insert(
            "The native Affinity document could not be read (\(native)). Opened only its embedded \(p.width)×\(p.height) PNG preview, which may be smaller than the document: no layers, vectors, text or pages. Save a new copy; the Affinity source cannot be saved back. Export PSD or PNG from Affinity for full-resolution artwork.",
            at: 0
        )
        return r
    }

    /// A decoded flat image as a one-layer document (the part of photocraft's
    /// `flat::image_to_document` the preview needs): an opaque image opens as the locked
    /// Background layer, one with an alpha channel as "Layer 0".
    static func imageToDocument(_ name: String, _ img: DecodedImage) -> ImportResult {
        var warnings: [String] = []
        let fmt = img.surface.format
        var doc = Document(name: name, size: PixelSize(width: img.width, height: img.height), mode: fmt.mode, depth: fmt.sample)
        var surface = img.surface
        if surface.format != doc.pixelFormat, surface.format.mode == doc.pixelFormat.mode, surface.format.alpha == doc.pixelFormat.alpha {
            surface = surface.converted(to: doc.pixelFormat)
        }
        surface.prune()
        var layer = Layer(name: img.hasAlpha ? "Layer 0" : "Background", content: .raster(surface))
        if !img.hasAlpha {
            layer.locks.transparency = true
            layer.locks.position = true
        }
        doc.layers = [layer]
        doc.iccProfile = img.iccProfile
        if let d = img.dpi {
            doc.resolutionDpi = Float(d.x)
            if let w = unequalResolutionWarning(d.x, d.y) { warnings.append(w) }
        }
        return ImportResult(document: doc, warnings: warnings, sourceReadOnly: false, previewOnly: false)
    }

    // MARK: - Type layers

    /// photocraft's `text_import::prepare` for one type layer, on the injected renderer: a run whose
    /// font came as a PostScript name gets the installed family it resolves to, and the layer is
    /// rendered from its model within `maxTextPixels` (the sizes and frames come from an untrusted
    /// file). photocraft walks the finished document; the builder calls this as each type layer is
    /// made, which needs no walk over a tree up to 128 levels deep. Without a renderer the cache
    /// stays nil.
    static func prepareText(_ t: inout TextLayer, _ renderer: any LayerContentRenderer, dpi: Float, format: PixelFormat) {
        var changed = false
        for i in t.runs.indices {
            guard let ps = t.runs[i].style.postscriptName, !renderer.hasFontFamily(t.runs[i].style.fontFamily),
                  let f = renderer.resolvePostScript(ps), f.exact || renderer.hasFontFamily(f.family) else { continue }
            t.runs[i].style.fontFamily = f.family
            t.runs[i].style.weight = f.weight
            t.runs[i].style.italic = f.italic
            changed = true
        }
        if changed { t.syncSummary() }
        if t.cache == nil {
            t.cache = renderer.renderText(t, format: format, dpi: dpi, maxPixels: maxTextPixels) ?? Surface(format: format)
        }
    }
}
