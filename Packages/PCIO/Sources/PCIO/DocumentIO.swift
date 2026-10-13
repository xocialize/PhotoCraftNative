// Import and export dispatch: PSD/PSB by signature, `.pcraft`, OpenRaster, Krita, Paint.NET, SVG,
// layered TIFF, and flat images through the injected codec.
// Port of photocraft-io (crates/io/src/lib.rs: import, import_with, export, export_with,
// is_svg_input, has_extension; text_import.rs: prepare; flat.rs: image_to_document), MIT OR
// Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Not here (other packages own them): camera raws and the flat codecs' full matrix (PCPlatform's
// `ImageCodecs`, injectable as the `FlatImageCodec`).

import CoreGraphics
import Foundation
import PCDocument
import PCFormat
import PCFoundation
import PCIOAffinity
import PCIOCore
import PCIOFormats
import PCIOMaps
import PCIOText
import PCPSD

/// Services and settings for an import or export.
public struct IOOptions: Sendable {
    /// Renders merged composites and previews. The default is PCRender (`RenderCompositor.shared`,
    /// Metal when available, else the CPU reference) with the placeholder rasterizer.
    public var compositor: any PCIOCore.DocumentCompositor
    /// Renders model-only layers (type, shapes, stale fills); nil keeps them empty, with warnings.
    public var renderer: (any LayerContentRenderer)?
    /// Flat image codec (PNGs inside containers, thumbnails, flat files).
    public var codec: any FlatImageCodec
    /// Cancellation and progress.
    public var interrupt: Interrupt
    /// SVG groups deeper than this are rasterised during conversion.
    public var maxSVGGroupDepth: Int
    /// Write PSB even for `.psd` names when the document is small.
    public var forcePSB: Bool
    /// PSD/PSB: embed the thumbnail resource (1036), Photoshop's "Always Save".
    public var imagePreviews: Bool
    /// TIFF: keep the layers (Photoshop layer data in tag 37724). Off by default, as photocraft's
    /// scripted saves; the app's Save As sets it from its Layers option.
    public var tiffLayers: Bool
    /// Smart-object source placement for regenerated filter caches (PCAlgo; see PSDExportOptions).
    public var placeSource: (@Sendable (Surface, PixelRect, PCAffine, [Double]?, Warp?) -> Surface?)?
    /// PSD/PSB: write records in Photoshop's own shape (see `PSDExportOptions`); false reproduces
    /// photocraft's records.
    public var photoshopRecordConventions = true
    /// The converter of a CMYK document's ICC profile (see `CMYKConverterFactory`); nil keeps the
    /// process-wide CMYK conversion (or an enclosing `ColorConvert.withCMYK` scope).
    public var cmykConverter: CMYKConverterFactory?

    public init(compositor: any PCIOCore.DocumentCompositor = RenderCompositor.shared, renderer: (any LayerContentRenderer)? = nil,
                codec: any FlatImageCodec = ImageIOCodec(), interrupt: Interrupt = .none, maxSVGGroupDepth: Int = maxGroupDepthLimit,
                forcePSB: Bool = false, imagePreviews: Bool = true, tiffLayers: Bool = false,
                placeSource: (@Sendable (Surface, PixelRect, PCAffine, [Double]?, Warp?) -> Surface?)? = nil) {
        self.compositor = compositor
        self.renderer = renderer
        self.codec = codec
        self.interrupt = interrupt
        self.maxSVGGroupDepth = maxSVGGroupDepth
        self.forcePSB = forcePSB
        self.imagePreviews = imagePreviews
        self.tiffLayers = tiffLayers
        self.placeSource = placeSource
    }

    func psdExportOptions(forcePSB: Bool, interrupt: Interrupt) -> PSDExportOptions {
        PSDExportOptions(compositor: compositor, renderer: renderer, forcePSB: forcePSB, imagePreviews: imagePreviews,
                         photoshopRecordConventions: photoshopRecordConventions, placeSource: placeSource, codec: codec, interrupt: interrupt)
    }
}

public enum DocumentIO {
    /// `true` if `bytes` start with the PSD/PSB signature.
    public static func isPSD(_ bytes: [UInt8]) -> Bool { bytes.starts(with: Array("8BPS".utf8)) }

    /// Imports a file. PSD/PSB and the containers are detected by signature; everything else is
    /// decoded with the flat codec.
    /// Runs `body` with a CMYK document's own profile as the CMYK conversion (when the options
    /// build a converter for it); anything else runs unchanged.
    static func cmykScope<R>(_ icc: [UInt8]?, _ mode: ColorMode, _ options: IOOptions, _ body: () throws -> R) rethrows -> R {
        guard mode == .cmyk, let icc, let converter = options.cmykConverter?(icc) else { return try body() }
        return try ColorConvert.withCMYK(converter, body)
    }

    public static func importFile(name: String, bytes: [UInt8], options: IOOptions = IOOptions()) throws -> ImportResult {
        try options.interrupt.check()
        let r = try importStages(name, bytes, options)
        try options.interrupt.check()
        options.interrupt.progress(1)
        return r
    }

    /// Imports a file from disk. PSD/PSB files are memory-mapped (a multi-gigabyte PSB reads only
    /// its structure until layers decode).
    public static func importFile(contentsOf url: URL, options: IOOptions = IOOptions()) throws -> ImportResult {
        // Compositor projects are document packages (directories), import-only.
        if CompImport.isPackage(url) {
            try options.interrupt.check()
            var r = try CompImport.importDocument(contentsOf: url, codec: options.codec, interrupt: options.interrupt)
            r.warnings += TextImport.prepare(&r.document, renderer: options.renderer)
            return r
        }
        let data: Data
        do { data = try Data(contentsOf: url, options: [.alwaysMapped]) } catch { throw PCIOError.io("\(error)") }
        let name = url.lastPathComponent
        if data.starts(with: Array("8BPS".utf8)) {
            let file: PSDFile
            do { file = try PSDFile(data: data) } catch { throw PCIOError.wrap(error) }
            return try importPSD(name, file, options)
        }
        return try importFile(name: name, bytes: [UInt8](data), options: options)
    }

    /// The import of a parsed PSD: group-depth check, mapping, then the type layers made ready
    /// (fonts resolved, missing pixels rendered).
    static func importPSD(_ name: String, _ file: PSDFile, _ options: IOOptions) throws -> ImportResult {
        // Nesting past the document model's cap could never be saved; reject with the limit.
        try PSDImport.checkGroupDepth(file)
        try options.interrupt.check()
        options.interrupt.progress(0.05)
        // A CMYK file's colours (stops, fills, styles) are read through its own profile.
        let icc = file.resource(PSDResourceID.iccProfile).map { [UInt8]($0.data) }
        return try cmykScope(icc, file.header.colorMode == .cmyk ? .cmyk : .rgb, options) {
            var (document, warnings) = try PSDImport.document(file, options: PSDImportOptions(renderer: options.renderer, interrupt: options.interrupt))
            document.name = name
            warnings += TextImport.prepare(&document, renderer: options.renderer)
            return ImportResult(document: document, warnings: warnings)
        }
    }

    static func importStages(_ name: String, _ bytes: [UInt8], _ options: IOOptions) throws -> ImportResult {
        // A declared native extension must reach its loader so malformed bundles keep format errors.
        if hasExtension(name, PcraftFormat.fileExtension) || PcraftFormat.isPcraft(bytes) {
            do { return ImportResult(document: try PcraftFormat.load(bytes)) } catch { throw PCIOError.format("pcraft", error.description) }
        }
        if isPSD(bytes) {
            let file: PSDFile
            do { file = try PSDFile(bytes: bytes) } catch { throw PCIOError.wrap(error) }
            return try importPSD(name, file, options)
        }
        if AffinityImport.isAffinity(bytes) || AffinityImport.hasExtension(name) {
            return try AffinityImport.importDocument(name: name, bytes: bytes, renderer: options.renderer, codec: options.codec)
        }
        if OpenRaster.isORA(bytes) || hasExtension(name, "ora") {
            return try OpenRaster.importDocument(name: name, bytes: bytes, codec: options.codec, interrupt: options.interrupt)
        }
        // Krita files are ZIP containers carrying a merged PNG. A recognised raster signature
        // still wins over a misleading .kra suffix.
        if Krita.isKRA(bytes) || (hasExtension(name, "kra") && !looksLikeImage(bytes)) {
            return try Krita.importDocument(name: name, bytes: bytes, codec: options.codec, interrupt: options.interrupt)
        }
        if hasExtension(name, "pdn") || bytes.starts(with: Array("PDN3".utf8)) {
            return try PaintDotNet.importDocument(name: name, bytes: bytes, interrupt: options.interrupt)
        }
        if isSVGInput(name, bytes) {
            return try SVGImport.importDocument(name: name, bytes: bytes, maxGroupDepth: options.maxSVGGroupDepth)
        }
        if let r = try TIFFLayers.importIfLayered(name, bytes, options) { return r }
        return try importFlat(name, bytes, codec: options.codec)
    }

    /// Extension names can be wrong (an image downloaded as WebP and renamed `.svg`). Valid plain
    /// SVG is recognised by its XML; an otherwise unknown `.svg` goes to the SVG parser for a
    /// useful error, and `.svgz` disambiguates gzip streams.
    static func isSVGInput(_ name: String, _ bytes: [UInt8]) -> Bool {
        SVGImport.isSVG(bytes) || (hasExtension(name, "svg") && !looksLikeImage(bytes)) || (hasExtension(name, "svgz") && Deflate.isGzip(bytes))
    }

    /// Raster signatures (photocraft `photocraft_codecs::detect`): PNG, JPEG, GIF, BMP, TIFF, WebP,
    /// PSD, HEIF/AVIF, JPEG 2000, JPEG XL, EXR, QOI, ICO.
    static func looksLikeImage(_ b: [UInt8]) -> Bool {
        func starts(_ s: [UInt8]) -> Bool { b.starts(with: s) }
        if starts([0x89, 0x50, 0x4E, 0x47]) || starts([0xFF, 0xD8, 0xFF]) || starts(Array("GIF8".utf8)) || starts(Array("BM".utf8)) { return true }
        if starts([0x49, 0x49, 42, 0]) || starts([0x4D, 0x4D, 0, 42]) || starts([0x49, 0x49, 43, 0]) || starts([0x4D, 0x4D, 0, 43]) { return true }
        if b.count >= 12, starts(Array("RIFF".utf8)), Array(b[8 ..< 12]) == Array("WEBP".utf8) { return true }
        if b.count >= 12, Array(b[4 ..< 8]) == Array("ftyp".utf8) { return true }
        if starts([0x76, 0x2F, 0x31, 0x01]) || starts(Array("qoif".utf8)) || starts(Array("8BPS".utf8)) || starts([0xFF, 0x0A]) { return true }
        if starts([0, 0, 0, 0x0C, 0x6A, 0x50, 0x20, 0x20]) || starts([0, 0, 1, 0]) { return true }
        return false
    }

    static func fileExtension(_ name: String) -> String {
        let last = name.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? name
        guard let dot = last.lastIndex(of: ".") else { return last.lowercased() }
        return String(last[last.index(after: dot)...]).lowercased()
    }

    static func hasExtension(_ name: String, _ expected: String) -> Bool {
        let last = name.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? name
        guard let dot = last.lastIndex(of: "."), dot != last.startIndex else { return false }
        return last[last.index(after: dot)...].lowercased() == expected.lowercased()
    }

    /// A flat image as a one-layer document: a locked "Background" when opaque, a normal
    /// "Layer 0" when it has transparency; depth and Gray/RGB/CMYK kept, ICC, resolution and
    /// metadata, turned upright by its EXIF/TIFF orientation (photocraft `flat::import_flat` +
    /// `image_to_document`, through the injected codec). OpenEXR and Radiance HDR without a
    /// profile are tagged linear.
    public static func importFlat(_ name: String, _ bytes: [UInt8], codec: any FlatImageCodec) throws -> ImportResult {
        var img: DecodedImage
        var partWarning: String?
        if let (part, total) = exrBestPart(bytes) {
            img = part
            partWarning = "only one of \(total) EXR parts was imported"
        } else {
            do { img = try codec.decode(bytes) } catch let e as PCIOError { throw e } catch { throw PCIOError.codec("\(error)") }
        }
        img = FlatOrientation.upright(img)
        var r = imageToDocument(name, img)
        if let w = partWarning { r.warnings.insert(w, at: 0) }
        // What a File › Save without a quality keeps: a JPEG's quality, a WebP's encoding.
        r.document.fileEncoding = SourceEncoding.fileEncoding(bytes)
        // OpenEXR and Radiance HDR hold linear, scene-referred values (Rec. 709 primaries).
        let linear = bytes.starts(with: [0x76, 0x2F, 0x31, 0x01]) || bytes.starts(with: Array("#?RADIANCE".utf8)) || bytes.starts(with: Array("#?RGBE".utf8))
        if linear, r.document.iccProfile == nil {
            let name: CFString? = r.document.mode == .rgb ? CGColorSpace.linearSRGB : r.document.mode == .grayscale ? CGColorSpace.linearGray : nil
            r.document.iccProfile = name.flatMap { CGColorSpace(name: $0)?.copyICCData() }.map { [UInt8]($0 as Data) }
        }
        return r
    }

    /// A multi-part OpenEXR opens at the part with the most colour (RGBA > RGB > YA > Y, the
    /// earliest on a tie), as photocraft-codecs' EXR decoder does (ImageIO reads the first part).
    /// nil for anything else, single-part files and parts the part decoder refuses (those go
    /// through the injected codec).
    static func exrBestPart(_ bytes: [UInt8]) -> (image: DecodedImage, parts: Int)? {
        guard bytes.starts(with: [0x76, 0x2F, 0x31, 0x01]), let parts = try? EXRParts.info(bytes), parts.count > 1 else { return nil }
        var best = parts[0]
        for p in parts.dropFirst() where p.colorRank > best.colorRank { best = p }
        guard let img = try? EXRParts.decodePart(bytes, best.index), img.width > 0, img.height > 0 else { return nil }
        let gray = img.layout == .gray || img.layout == .grayAlpha
        let alpha = img.layout == .grayAlpha || img.layout == .rgba
        let fmt = PixelFormat(mode: gray ? .grayscale : .rgb, sample: .f32, alpha: true)
        let inCh = img.layout.channels, outCh = fmt.channels
        guard img.samples.count >= img.width * img.height * inCh else { return nil }
        var surface = Surface(format: fmt)
        let rows = max(1, (32 << 20) / max(1, img.width * outCh * 4))
        var y = 0
        while y < img.height {
            let y1 = min(img.height, y + rows)
            var band = [Float](repeating: 1, count: (y1 - y) * img.width * outCh)
            for i in 0 ..< (y1 - y) * img.width {
                let at = (y * img.width + i) * inCh
                for c in 0 ..< inCh { band[i * outCh + c] = img.samples[at + c] }
            }
            surface.writeRegion(PixelRect(x0: 0, y0: Int32(y), x1: Int32(img.width), y1: Int32(y1)), band)
            y = y1
        }
        surface.prune()
        return (DecodedImage(surface: surface, width: img.width, height: img.height, hasAlpha: alpha, halfFloat: img.half), parts.count)
    }

    /// `importFlat` for an already decoded (and oriented) image.
    public static func imageToDocument(_ name: String, _ img: DecodedImage) -> ImportResult {
        // What the decoder noticed (frames or pages left out, data ending early) comes first.
        var warnings = img.warnings
        if img.halfFloat { warnings.append("16-bit float samples are stored as 32-bit float") }
        let fmt = img.surface.format
        var doc = Document(name: name, size: PixelSize(width: img.width, height: img.height), mode: fmt.mode, depth: fmt.sample)
        doc.iccProfile = img.iccProfile
        doc.metadata.exif = img.exif
        doc.metadata.xmp = img.xmp
        doc.metadata.text = img.text
        // Without a resolution of the format's own, the EXIF or XMP one counts, like Photoshop.
        let dpi = img.dpi ?? img.exif.flatMap(MetadataExport.exifResolution).map { (Double($0.0), Double($0.1)) }
            ?? img.xmp.flatMap(MetadataExport.xmpResolution).map { (Double($0.0), Double($0.1)) }
        if let d = dpi {
            doc.resolutionDpi = Float(d.0)
            if let w = unequalResolutionWarning(d.0, d.1) { warnings.append(w) }
        }
        var surface = img.surface
        if surface.format != doc.pixelFormat, surface.format.mode == doc.pixelFormat.mode { surface = surface.converted(to: doc.pixelFormat) }
        // As in Photoshop: an opaque image opens as the locked Background layer, one with an
        // alpha channel as a normal layer named "Layer 0" (a Background can't hold transparency).
        var l = Layer(name: img.hasAlpha ? "Layer 0" : "Background", content: .raster(surface))
        if !img.hasAlpha {
            l.locks.transparency = true
            l.locks.position = true
        }
        doc.layers = [l]
        return ImportResult(document: doc, warnings: warnings)
    }

    /// Exports `doc` to the format named by `nameOrExt` (a file name, path or bare extension).
    public static func export(_ doc: Document, as nameOrExt: String, options: IOOptions = IOOptions()) throws -> ExportResult {
        try options.interrupt.check()
        // A CMYK document's colours (fills, the merged image) are separated through its own profile.
        let r = try cmykScope(doc.iccProfile, doc.mode, options) { try exportStages(doc, nameOrExt, options) }
        try options.interrupt.check()
        options.interrupt.progress(1)
        return r
    }

    static func exportStages(_ doc: Document, _ nameOrExt: String, _ options: IOOptions) throws -> ExportResult {
        let ext = nameOrExt.contains(".") || nameOrExt.contains("/") ? fileExtension(nameOrExt) : nameOrExt.lowercased()
        switch ext {
        case "pdn":
            throw PCIOError.unsupported("PDN is import-only; save as .pcraft to preserve all layers and blend modes")
        case "af", "afdesign", "afphoto", "afpub":
            throw PCIOError.unsupported("Affinity export is not implemented; save a new PSD, PNG or .pcraft copy")
        case "ora":
            return try OpenRaster.export(doc, compositor: options.compositor, codec: options.codec)
        case PcraftFormat.fileExtension:
            let thumbnail = try preview(doc, side: 256, options)
            try options.interrupt.check()
            options.interrupt.progress(0.15)
            let composite = try preview(doc, side: 1024, options)
            try options.interrupt.check()
            options.interrupt.progress(0.4)
            do {
                return ExportResult(bytes: try PcraftFormat.save(doc, options: SaveOptions(thumbnail: thumbnail, composite: composite)))
            } catch { throw PCIOError.format("pcraft", error.description) }
        case "psd", "psb":
            return try PSDExport.export(doc, options: options.psdExportOptions(forcePSB: options.forcePSB || ext == "psb", interrupt: options.interrupt))
        case "tif", "tiff":
            if options.tiffLayers, TIFFLayers.wouldWriteLayers(doc) { return try TIFFLayers.exportLayered(doc, options) }
            return try exportFlat(doc, .tiff, options)
        case "png":
            return try exportFlat(doc, .png, options)
        case "jpg", "jpeg":
            return try exportFlat(doc, .jpeg, options)
        default:
            throw PCIOError.unknownFormat("\(nameOrExt) (flat formats beyond PNG/JPEG/TIFF are PCPlatform's ImageCodecs)")
        }
    }

    /// The previews a `.pcraft` save embeds, a 256-px thumbnail and a 1024-px composite, rendered
    /// as the single-file export renders them: for package saves (`PcraftWriter.save(_:to:as:_:)`).
    public static func pcraftPreviews(_ doc: Document, options: IOOptions) throws -> SaveOptions {
        try cmykScope(doc.iccProfile, doc.mode, options) {
            SaveOptions(thumbnail: try preview(doc, side: 256, options), composite: try preview(doc, side: 1024, options))
        }
    }

    /// The composite reduced to fit `side`, as an RGBA8 preview (photocraft `compose::thumbnail`).
    static func preview(_ doc: Document, side: Int, _ options: IOOptions) throws -> RGBA8Image? {
        guard doc.size.width > 0, doc.size.height > 0 else { return nil }
        let (px, w, h) = try PSDThumbnail.thumbnailRGBA(doc, compositor: options.compositor, side: side)
        var data = [UInt8](repeating: 0, count: w * h * 4)
        for i in 0 ..< w * h {
            for c in 0 ..< 4 { data[i * 4 + c] = PSDExport.q255(px[i][c]) }
        }
        return RGBA8Image(width: w, height: h, data: data)
    }

    /// A flattened export through the injected codec (photocraft `flat::export_flat`): a single
    /// plain raster layer keeps its model and depth; anything else is composited (CMYK and Lab
    /// become sRGB RGB); the alpha is dropped when every pixel is opaque; JPEG mattes transparency
    /// over white, PNG takes CMYK as sRGB; EXIF, XMP, text and resolution are embedded,
    /// normalised (orientation 1, the saved resolution, no stale thumbnail).
    static func exportFlat(_ doc: Document, _ type: FlatImageType, _ options: IOOptions) throws -> ExportResult {
        if let r = try exportModeSpecific(doc, type, options) { return r }
        let fmt = doc.pixelFormat
        let canvas = doc.bounds
        let typeName = type == .png ? "Png" : type == .jpeg ? "Jpeg" : "Tiff"
        var warnings: [String] = []
        var icc = doc.iccProfile
        var surface: Surface
        // The composite's share of the export; the encoder takes the rest (photocraft
        // `composite_share`, measured on 24 MP RGB/8).
        let share: Float = type == .tiff ? 0.3 : type == .jpeg ? 0.55 : 0.7
        let interrupt = options.interrupt
        try interrupt.check()
        if let s = singleLayer(doc), fmt.mode != .lab {
            surface = s
        } else {
            var count = 0
            doc.forEachLayer { _, _, _ in count += 1 }
            warnings.append("\(count) layer(s) flattened; layers, masks and blend modes are not kept")
            var s = Surface(format: fmt)
            // Rendered a band of rows at a time, reporting progress and checking for cancellation.
            let rows = max(1, (32 << 20) / max(1, canvas.width * fmt.channels * 4))
            var y = canvas.y0
            while y < canvas.y1 {
                let band = PixelRect(x0: canvas.x0, y0: y, x1: canvas.x1, y1: Int32(min(Int(canvas.y1), Int(y) + rows)))
                do { s.writeRegion(band, try options.compositor.composite(doc, rect: band)) } catch { throw PCIOError.wrap(error) }
                y = band.y1
                interrupt.progress(share * Float(y - canvas.y0) / Float(max(1, canvas.height)))
                try interrupt.check()
            }
            if fmt.mode == .cmyk || fmt.mode == .lab {
                // The composite of a CMYK/Lab document is written as sRGB, tagged as such.
                warnings.append("\(fmt.mode == .cmyk ? "Cmyk" : "Lab") composite written as sRGB RGB (colour-managed conversion)")
                s = srgb(s, canvas)
                icc = CGColorSpace(name: CGColorSpace.sRGB)?.copyICCData().map { [UInt8]($0 as Data) }
            }
            surface = s
        }
        let opaque = isOpaque(surface, canvas)
        if !opaque, type == .jpeg {
            // Flattened over white, as saving a transparent document without transparency does.
            surface = matteOverWhite(surface, canvas)
            warnings.append("transparency composited over white for \(typeName)")
        }
        if surface.format.mode == .cmyk, type == .png {
            surface = srgb(surface, canvas)
            icc = CGColorSpace(name: CGColorSpace.sRGB)?.copyICCData().map { [UInt8]($0 as Data) }
            warnings.append("CMYK converted to sRGB for \(typeName) through the document's colour profile")
        }
        if opaque || type == .jpeg, surface.format.alpha {
            // The codec writes alpha when the surface has it: drop it.
            surface = withoutAlpha(surface, canvas)
        }
        interrupt.progress(share)
        try interrupt.check()
        let ppi: (Float, Float)? = doc.resolutionDpi > 0 ? (doc.resolutionDpi, doc.resolutionDpi) : nil
        let meta = FlatMetadata.Metadata(exif: doc.metadata.exif.map { MetadataExport.exportExif($0, ppi) },
                                         xmp: doc.metadata.xmp.map { MetadataExport.exportXmp($0, ppi) }, text: doc.metadata.text)
        warnings += fidelityWarnings(surface, canvas, type, meta)
        let dpi: Double? = doc.resolutionDpi > 0 ? Double(doc.resolutionDpi) : nil
        if type == .tiff {
            // PCIO's own TIFF writer (photocraft writes TIFF with its own codec too): every mode
            // and depth with straight alpha (CMYK + alpha included), the profile as given, XMP,
            // text tags and the resolution.
            let f = surface.format
            let image = LayeredTIFF.Image(width: canvas.width, height: canvas.height, mode: f.mode, alpha: f.alpha, sample: f.sample,
                                          samples: surface.readInterleaved(canvas), iccProfile: icc, xmp: meta.xmp.map { Array($0.utf8) },
                                          dpi: dpi.map { ($0, $0) },
                                          text: meta.text.compactMap { t in LayeredTIFF.textTags.first { TIFFLayers.tagName($0) == t.key }.map { ($0, t.value) } },
                                          photoshopResources: nil, photoshopLayers: nil)
            let order: PSDTIFF.ByteOrder = LayeredTIFF.writesLittleEndian ? .little : .big
            let bytes = try LayeredTIFF.write(image, options: LayeredTIFF.WriteOptions(byteOrder: order))
            return ExportResult(bytes: bytes, warnings: warnings)
        }
        let bytes = try options.codec.encode(surface, rect: canvas, as: type, quality: type == .jpeg ? 0.9 : nil, iccProfile: icc, metadata: meta, dpi: dpi)
        return ExportResult(bytes: bytes, warnings: warnings)
    }

    /// What writing `s` as `type` loses (photocraft-codecs `fidelity_warnings_with` for PNG, JPEG
    /// and TIFF: depth, HDR range, lossy compression, metadata the format can't hold or fit).
    static func fidelityWarnings(_ s: Surface, _ r: PixelRect, _ type: FlatImageType, _ meta: FlatMetadata.Metadata) -> [String] {
        var w: [String] = []
        func depthName(_ t: SampleType) -> String { t == .u8 ? "8-bit" : t == .u16 ? "16-bit" : "32-bit float" }
        let from = s.format.sample
        let to: SampleType = type == .jpeg ? .u8 : type == .png && from == .f32 ? .u16 : from
        if from != to, from != .u8 { w.append("\(depthName(from)) will be reduced to \(depthName(to))") }
        if from == .f32, to != .f32 {
            var out = false
            var y = r.y0
            while !out, y < r.y1 {
                let band = PixelRect(x0: r.x0, y0: y, x1: r.x1, y1: min(r.y1, y &+ 256))
                out = s.readRegion(band).contains { $0 < 0 || $0 > 1 }
                y = band.y1
            }
            if out { w.append("HDR values outside 0..1 will be clipped") }
        }
        if type == .jpeg { w.append("lossy compression") }
        if type == .tiff, meta.exif != nil { w.append("EXIF not supported; it will be dropped") }
        if type == .jpeg {
            if !meta.text.isEmpty { w.append("text metadata not supported; it will be dropped") }
            if let e = meta.exif, FlatMetadata.exifHeader.count + e.count > 65533 {
                w.append("EXIF (\(e.count) bytes) is too large for the format; it will be dropped")
            }
            if let x = meta.xmp {
                let trimmed = FlatMetadata.layeredOnlyXMP.reduce(x) { FlatMetadata.removingXMPElement($0, $1) }
                if FlatMetadata.xmpHeader.count + trimmed.utf8.count > 65533 {
                    w.append("XMP (\(x.utf8.count) bytes) is too large for the format; it will be dropped")
                }
            }
        }
        return w
    }

    /// Indexed Color as an 8-bit palette PNG (its colour table, nearest entries, the transparent
    /// entry under alpha < ½); Duotone as the inks rendered to RGB (photocraft
    /// `flat::export_mode_specific`). nil for every other case.
    static func exportModeSpecific(_ doc: Document, _ type: FlatImageType, _ options: IOOptions) throws -> ExportResult? {
        switch doc.mode {
        case .indexed where type == .png:
            guard let table = doc.colorTable, !table.colors.isEmpty, table.colors.count <= 256 else { return nil }
            let canvas = doc.bounds
            var s = Surface(format: doc.pixelFormat)
            do { s.writeRegion(canvas, try options.compositor.composite(doc, rect: canvas)) } catch { throw PCIOError.wrap(error) }
            try options.interrupt.check()
            let idx: [UInt8] = s.readRGBA(canvas).map { p in
                if let t = table.transparent, p.w < 0.5 { return t }
                return UInt8(table.nearest(SIMD3(p.x, p.y, p.z)))
            }
            let bytes = try IndexedPNG.encode(width: doc.size.width, height: doc.size.height, indices: idx, palette: table.colors,
                                              transparent: table.transparent, dpi: doc.resolutionDpi > 0 ? Double(doc.resolutionDpi) : nil)
            var warnings = ["written as an 8-bit palette PNG (\(table.colors.count) colours)"]
            if !doc.metadata.text.isEmpty { warnings.append("text metadata is not supported by the palette PNG exporter; it will be dropped") }
            return ExportResult(bytes: bytes, warnings: warnings)
        case .duotone:
            guard let d = doc.duotone else { return nil }
            var shown = doc
            shown.layers.append(Layer(name: "Duotone", content: .adjustment(d.displayAdjustment)))
            shown.mode = .rgb
            shown.iccProfile = nil
            shown.duotone = nil
            var r = try exportFlat(shown, type, options)
            r.warnings.removeAll { $0.contains("flattened") }
            r.warnings.append("Duotone (\(d.inks.count) inks) written as RGB")
            return r
        default:
            return nil
        }
    }

    /// The one layer a flat file can hold as it is (photocraft `flat::single_layer`): a visible,
    /// fully opaque, Normal, unmasked, effect-free raster layer in the document's own format.
    static func singleLayer(_ doc: Document) -> Surface? {
        guard doc.layers.count == 1, let l = doc.layers.first, case let .raster(s) = l.content else { return nil }
        let ok = l.visible && l.opacity >= 1 && l.fillOpacity >= 1 && l.mask == nil && !(l.vectorMask?.enabled ?? false) && l.effects.items.isEmpty
            && l.effects.psdRaw == nil && (l.blend == .normal || l.blend == .passThrough) && l.excludedChannels == 0 && l.blendIf.isDefault
        return ok && s.format == doc.pixelFormat ? s : nil
    }

    static func isOpaque(_ s: Surface, _ r: PixelRect) -> Bool {
        guard s.format.alpha else { return true }
        let ch = s.format.channels
        var y = r.y0
        while y < r.y1 {
            let band = PixelRect(x0: r.x0, y0: y, x1: r.x1, y1: min(r.y1, y &+ 256))
            let v = s.readRegion(band)
            if !stride(from: ch - 1, to: v.count, by: ch).allSatisfy({ v[$0] >= 1 }) { return false }
            y = band.y1
        }
        return true
    }

    /// Applies `f` to every pixel of `s` over `r`, a band of rows at a time, into `format`.
    static func mapPixels(_ s: Surface, _ r: PixelRect, _ format: PixelFormat, _ f: ([Float], inout [Float], Int, Int) -> Void) -> Surface {
        var out = Surface(format: format)
        let (inCh, outCh) = (s.format.channels, format.channels)
        var y = r.y0
        while y < r.y1 {
            let band = PixelRect(x0: r.x0, y0: y, x1: r.x1, y1: min(r.y1, y &+ 256))
            let v = s.readRegion(band)
            var o = [Float](repeating: 0, count: band.area * outCh)
            for i in 0 ..< band.area { f(v, &o, i * inCh, i * outCh) }
            out.writeRegion(band, o)
            y = band.y1
        }
        out.prune()
        return out
    }

    /// `s` as sRGB RGB at its depth (the model's colour conversion).
    static func srgb(_ s: Surface, _ r: PixelRect) -> Surface {
        let fmt = PixelFormat(mode: .rgb, sample: s.format.sample == .f32 ? .f32 : s.format.sample, alpha: true)
        var out = Surface(format: fmt)
        var y = r.y0
        while y < r.y1 {
            let band = PixelRect(x0: r.x0, y0: y, x1: r.x1, y1: min(r.y1, y &+ 256))
            out.writeRegion(band, s.readRGBA(band).flatMap { [$0.x, $0.y, $0.z, $0.w] })
            y = band.y1
        }
        out.prune()
        return out
    }

    /// `s` composited over white, opaque.
    static func matteOverWhite(_ s: Surface, _ r: PixelRect) -> Surface {
        let fmt = s.format
        let white = fmt.components(fromRGBA: SIMD4(1, 1, 1, 1))
        let cc = fmt.channels - 1
        return mapPixels(s, r, fmt) { v, o, i, k in
            let a = v[i + cc]
            for c in 0 ..< cc { o[k + c] = v[i + c] * a + white[c] * (1 - a) }
            o[k + cc] = 1
        }
    }

    /// `s` without its alpha channel.
    static func withoutAlpha(_ s: Surface, _ r: PixelRect) -> Surface {
        let fmt = PixelFormat(mode: s.format.mode, sample: s.format.sample, alpha: false)
        let cc = fmt.channels
        return mapPixels(s, r, fmt) { v, o, i, k in for c in 0 ..< cc { o[k + c] = v[i + c] } }
    }
}

/// Type layers read from a file, made ready for the canvas and the panels.
/// Port of photocraft-io (crates/io/src/text_import.rs).
enum TextImport {
    /// Largest type raster the import draws on its own (pixels): the model comes from an untrusted
    /// file, and an absurd size or box must not make opening it allocate gigabytes.
    static let maxRenderPixels: UInt64 = 64 * 1024 * 1024

    /// Prepares the type layers of a document that was just imported:
    /// - a run whose font came as a PostScript name gets the installed family that name resolves
    ///   to, so Missing Fonts and the Character panel see the real family;
    /// - a type layer without pixels (ag-psd, GIMP and other writers leave the image data out and
    ///   let Photoshop re-render on open) is rendered from its model.
    static func prepare(_ doc: inout Document, renderer: (any LayerContentRenderer)?) -> [String] {
        guard let renderer else {
            var missing = 0
            doc.forEachLayer { _, _, l in if case let .text(t) = l.content, t.cache == nil { missing += 1 } }
            return missing > 0 ? ["\(missing) type layer(s) have no stored pixels and no text renderer was given; they show empty until rendered"] : []
        }
        let dpi = doc.resolutionDpi
        let format = doc.pixelFormat
        doc.forEachLayerMut { l in
            l.withText { t in
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
                    t.cache = renderer.renderText(t, format: format, dpi: dpi, maxPixels: maxRenderPixels) ?? Surface(format: format)
                }
            }
        }
        return []
    }
}
