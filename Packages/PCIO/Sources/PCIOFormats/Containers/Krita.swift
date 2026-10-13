// Port of photocraft-io (crates/io/src/kra.rs, and the parts of crates/io/src/flat.rs
// `image_to_document` it uses), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft
// contributors.
//
// Krita .kra import: the merged PNG is an editable raster layer, not a replacement for Krita's
// native layer tree. Never write this document back to the .kra source. The ZIP reader checks
// entry bounds, sizes and CRC before the PNG decoder (the injected `FlatImageCodec`) runs.

import Foundation
import PCDocument
import PCFoundation
import PCIOCore

/// Krita document import (the archive's merged image, as one editable layer).
public enum Krita {
    /// The `mimetype` entry of a Krita archive.
    public static let mimetype: [UInt8] = Array("application/x-krita".utf8)
    static let maxEntry = 512 << 20
    static let maxPixelBytes = 1 << 30

    static func invalid(_ message: String) -> PCIOError { .format("Krita", message) }

    /// Krita writes its mimetype as the first, uncompressed ZIP entry.
    public static func isKRA(_ bytes: [UInt8]) -> Bool {
        guard let mime = ZipReader.mimetype(bytes) else { return false }
        return OpenRaster.trimASCII(mime) == mimetype
    }

    /// Imports Krita's official merged preview as a flattened, editable document. This does not
    /// pretend to import a layered or lossless Krita document: the result is read-only as a
    /// source and says so in a warning.
    public static func importDocument(name: String, bytes: [UInt8], codec: any FlatImageCodec, interrupt ctl: Interrupt) throws -> ImportResult {
        try ctl.check()
        let archive: ZipReader
        do { archive = try ZipReader(bytes) } catch { throw invalid(OpenRaster.errorText(error)) }
        let mime: [UInt8]
        do { mime = try archive.read(named: "mimetype", max: 256) } catch { throw invalid(OpenRaster.errorText(error)) }
        if OpenRaster.trimASCII(mime) != mimetype {
            throw invalid("the archive's mimetype is not application/x-krita")
        }
        ctl.progress(0.10)
        let merged: [UInt8]
        do { merged = try archive.read(named: "mergedimage.png", max: maxEntry) } catch {
            throw invalid("mergedimage.png: \(OpenRaster.errorText(error))")
        }
        guard OpenRaster.isPNG(merged) else {
            throw invalid("mergedimage.png is not a PNG image")
        }
        try ctl.check()
        // The decoder limits photocraft passes: 300,000 px a side and 1 GiB decoded.
        if let header = OpenRaster.pngHeader(merged), let e = OpenRaster.limitError(header, maxAlloc: maxPixelBytes) {
            throw invalid("mergedimage.png: \(e)")
        }
        let image: DecodedImage
        do { image = try codec.decode(merged) } catch { throw invalid("mergedimage.png: \(OpenRaster.errorText(error))") }
        if image.width < 1 || image.height < 1 || image.width > OpenRaster.maxSide || image.height > OpenRaster.maxSide {
            throw invalid("mergedimage.png: limit exceeded: dimensions \(image.width)x\(image.height) exceed max \(OpenRaster.maxSide)x\(OpenRaster.maxSide)")
        }
        try ctl.check()
        var result = imageToDocument(name, image)
        result.sourceReadOnly = true
        result.warnings.append("Krita layers, masks and editable document structure were not imported; only mergedimage.png is available")
        return result
    }

    /// A decoded flat image as a single-layer document: a locked "Background" when it is opaque,
    /// a normal "Layer 0" when it has transparency; depth, Gray/RGB/CMYK, ICC profile and
    /// resolution kept (photocraft `flat::image_to_document`).
    ///
    /// photocraft also copies EXIF, XMP and text metadata and warns about 16-bit float samples;
    /// `DecodedImage` carries neither, so those are not available here.
    static func imageToDocument(_ name: String, _ img: DecodedImage) -> ImportResult {
        var warnings: [String] = []
        let fmt = img.surface.format
        let mode: ColorMode
        switch fmt.mode {
        case .grayscale, .bitmap, .duotone: mode = .grayscale
        case .cmyk: mode = .cmyk
        default: mode = .rgb
        }
        var doc = Document(name: name, size: PixelSize(width: img.width, height: img.height), mode: mode, depth: fmt.sample)
        var s = img.surface
        let target = PixelFormat(mode: mode, sample: fmt.sample, alpha: true)
        if s.format != target {
            // The codec contract is Gray/RGB/CMYK with alpha; anything else is converted.
            var t = Surface(format: target)
            let r = PixelRect(x0: 0, y0: 0, x1: Int32(clamping: img.width), y1: Int32(clamping: img.height))
            if target.mode == .rgb {
                OpenRaster.writeConverted(s, img.width, img.height, into: &t, at: r)
            } else {
                t.writeRGBA(r, s.readRGBA(r))
            }
            s = t
        }
        s.prune()
        // As in Photoshop: an opaque image opens as the locked Background layer, one with
        // transparency as a normal layer named "Layer 0", since a Background can't hold
        // transparency.
        let layer: Layer
        if img.hasAlpha {
            layer = Layer(name: "Layer 0", content: .raster(s))
        } else {
            var bg = Layer(name: "Background", content: .raster(s))
            bg.locks.transparency = true
            bg.locks.position = true
            layer = bg
        }
        doc.layers.append(layer)
        doc.iccProfile = img.iccProfile
        if let dpi = img.dpi {
            doc.resolutionDpi = Float(dpi.x)
            if let w = unequalResolutionWarning(dpi.x, dpi.y) { warnings.append(w) }
        }
        return ImportResult(document: doc, warnings: warnings, sourceReadOnly: false, previewOnly: false)
    }
}
