// Port of photocraft-engine's file glue (crates/engine/src/file_cmds.rs `import`, `save_doc`, `flattened`; lib.rs `Session::open_document`; the injections photocraft-io takes from compose, text, vector and codecs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// The one place documents meet files: PCIO (PSD/PSB, .pcraft, OpenRaster, Krita, Paint.NET,
// layered TIFF, multi-part EXR, SVG, Affinity, flat images) with the services only the engine may
// hold injected —
// * the export composite and previews from the engine's PCRender compositor (`EngineRenderer`,
//   PCPlatform's rasterizer behind it, so type, shapes, vector masks and smart objects render),
// * model-only layers (type and shapes without pixels, stale fills) rendered by PCPlatform's
//   `TextEngine` / `VectorRasterizer` and the compositor (`PlatformContentRenderer`),
// * flat images through PCPlatform's `ImageCodecs` at native depth (`PlatformImageCodec`), and
// * smart-object placement through PCAlgo (`placeSource`).
// Formats PCIO doesn't write (WebP, GIF, BMP, TGA, EXR, HEIC, AVIF, JPEG XL, QOI, …) are encoded
// from the composite by `ImageCodecs` directly, as photocraft's codecs do.

import CoreGraphics
import Foundation
import PCAlgo
import PCDocument
import PCFormat
import PCFoundation
import PCIO
import PCIOCore
import PCIOFormats
import PCPlatform
import PCRender

extension EngineRenderer: PCIOCore.DocumentCompositor {
    /// The `.pcraft` previews' composite: PCRender's own reduction for an RGB document, whose
    /// composite reads back as rendered; the band-by-band default for the others.
    public func reduced(_ document: Document, width: Int, height: Int) throws -> [SIMD4<Float>] {
        guard document.pixelFormat.mode == .rgb else { return try ReducedComposite.reduce(document, width: width, height: height, compositor: self) }
        return try renderReduced(document, width: width, height: height).px
    }

    /// Only the damaged cells, through PCRender, for an RGB document (the whole reduction for the others).
    public func reduced(_ document: Document, width: Int, height: Int, damage: PixelRect) throws -> (rect: PixelRect, pixels: [SIMD4<Float>]) {
        guard document.pixelFormat.mode == .rgb else {
            let rect = ReducedComposite.cells(meeting: damage, canvas: document.size, width: width, height: height)
            return rect.isEmpty ? (rect, []) : (rect, ReducedComposite.crop(try reduced(document, width: width, height: height), width: width, rect))
        }
        let b = try renderReduced(document, width: width, height: height, damage: damage)
        return (b.rect, b.px)
    }
}

/// PCIO's `LayerContentRenderer` on PCPlatform: type through `TextEngine`, shapes through
/// `VectorRasterizer`, fonts through `FontCatalog`. Fill layers need nothing here: PCIO draws them
/// with PCRender's `FillLayerRenderer`, the compositor's own code.
public struct PlatformContentRenderer: LayerContentRenderer {
    public let renderer: EngineRenderer

    public init(renderer: EngineRenderer = .shared) { self.renderer = renderer }

    public func renderShape(_ shape: ShapeLayer, format: PixelFormat, canvas: PixelRect) -> Surface? {
        VectorRasterizer.rasterize(shape, format: format, clip: canvas)
    }

    public func renderText(_ text: TextLayer, format: PixelFormat, dpi: Float, maxPixels: UInt64) -> Surface? {
        TypeCommands.fonts {
            let r = TextEngine.rasterize(text, dpi: Double(dpi), format: format)
            if UInt64(max(r.rect.area, 0)) > maxPixels { return nil }
            return r.rect.isEmpty ? Surface(format: format) : r.surface
        }
    }

    public func hasFontFamily(_ family: String) -> Bool {
        TypeCommands.fonts { !FontCatalog.faces(family: family).isEmpty }
    }

    public func resolvePostScript(_ name: String) -> PCIOCore.ResolvedFont? {
        TypeCommands.fonts {
            guard let f = FontCatalog.face(postScriptName: name) else { return nil }
            return PCIOCore.ResolvedFont(family: f.family, weight: UInt16(clamping: f.weight), italic: f.italic, exact: f.postScriptName == name)
        }
    }
}

/// PCIO's `FlatImageCodec` on PCPlatform's `ImageCodecs`: every format PCPlatform reads, at native
/// depth, with the container metadata (EXIF, XMP, text, ICC, PNG resolution) read exactly as
/// PCIO's own reader does. Encoding with EXIF/XMP/text goes through PCIO's ImageIO writer, which
/// embeds them byte-exact; plain encodes through `ImageCodecs`.
public struct PlatformImageCodec: FlatImageCodec {
    /// Overrides the JPEG quality PCIO asks for (0…1), from a save's own quality.
    public var jpegQuality: Double?

    public init(jpegQuality: Double? = nil) { self.jpegQuality = jpegQuality }

    func quality(_ type: FlatImageType, _ asked: Double?) -> Double? { type == .jpeg ? (jpegQuality ?? asked) : asked }

    public func decode(_ data: [UInt8]) throws -> PCIOCore.DecodedImage {
        var opts = DecodeOptions()
        opts.keepOrientation = true
        let img: PCPlatform.DecodedImage
        do { img = try ImageCodecs.decode(Data(data), options: opts) } catch { throw PCIOError.codec("\(error)") }
        var surface = img.surface
        let hasAlpha = surface.format.alpha
        // An added alpha is opaque, the default pixel's too: the image's own pixels keep it, and the
        // surface reads transparent past them, as every layer the engine makes does (AB-T-0422/0423).
        if !hasAlpha {
            surface = surface.convertedAny(to: surface.format.with(alpha: true))
                .withTransparentDefault(within: PixelRect(size: PixelSize(width: img.size.width, height: img.size.height)))
        }
        let meta = FlatMetadata.read(data)
        var dpi = img.metadata.resolution.map { (x: $0.x, y: $0.y) }
        if FlatMetadata.formatName(data) == "PNG" { dpi = meta.dpi.map { (x: $0.x, y: $0.y) } }
        let icc = meta.container ? meta.icc : img.profile.map { [UInt8]($0.data) }
        return PCIOCore.DecodedImage(surface: surface, width: img.size.width, height: img.size.height, hasAlpha: hasAlpha, iccProfile: icc, dpi: dpi,
                                     exif: meta.exif, xmp: meta.xmp, text: meta.text, orientation: img.metadata.orientation,
                                     halfFloat: img.storedDepth == .f16, warnings: img.warnings.map(\.description))
    }

    public func encode(_ surface: Surface, rect: PixelRect, as type: FlatImageType, quality: Double?, iccProfile: [UInt8]?) throws -> [UInt8] {
        var o = EncodeOptions()
        if let q = self.quality(type, quality) {
            o.jpegQuality = Int((min(max(q, 0), 1) * 100).rounded())
            o.lossyQuality = min(max(q, 0), 1)
        }
        let profile = iccProfile.flatMap { try? ICCProfile(data: Data($0)) }
        do {
            return [UInt8](try ImageCodecs.encode(surface, rect: rect, as: Self.format(type), profile: profile, options: o))
        } catch {
            throw PCIOError.codec("\(error)")
        }
    }

    public func encode(_ surface: Surface, rect: PixelRect, as type: FlatImageType, quality: Double?, iccProfile: [UInt8]?,
                       metadata: FlatMetadata.Metadata, dpi: Double?) throws -> [UInt8] {
        if metadata.exif != nil || metadata.xmp != nil || !metadata.text.isEmpty || dpi != nil {
            return try ImageIOCodec().encode(surface, rect: rect, as: type, quality: self.quality(type, quality), iccProfile: iccProfile,
                                             metadata: metadata, dpi: dpi)
        }
        return try encode(surface, rect: rect, as: type, quality: quality, iccProfile: iccProfile)
    }

    static func format(_ t: FlatImageType) -> ImageFormat {
        switch t {
        case .png: .png
        case .jpeg: .jpeg
        case .tiff: .tiff
        }
    }
}

/// The engine's import/export entry points (photocraft `file_cmds::import` / `save_doc`).
public enum EngineIO {
    /// PCIO's options with the engine's services.
    public static func options(_ services: EngineServices, interrupt: Interrupt = .none, jpegQuality: Double? = nil) -> IOOptions {
        var o = IOOptions(compositor: services.renderer, renderer: PlatformContentRenderer(renderer: services.renderer),
                          codec: PlatformImageCodec(jpegQuality: jpegQuality), interrupt: interrupt, placeSource: placeSource)
        o.photoshopRecordConventions = true
        o.cmykConverter = { DocumentCMYK.converter(forProfile: $0) }
        return o
    }

    /// An `Interrupt` driven by a job's context.
    public static func interrupt(_ ctx: JobContext?) -> Interrupt {
        guard let ctx else { return .none }
        return Interrupt(cancel: { ctx.isCancelled }, progress: { ctx.progress($0) })
    }

    /// Places a smart object's source (photocraft-algo `warp::place_source[_projective]`).
    public static let placeSource: @Sendable (Surface, PixelRect, PCAffine, [Double]?, Warp?) -> Surface? = { src, bounds, t, persp, warp in
        let w = warp.map { WarpCommands.mapper($0) }
        if let p = persp, p.count == 9 {
            return MeshWarp.placeSourceProjective(src, srcRect: bounds, h: Homography(p), warp: w, on: .cpu)
        }
        let a = CGAffineTransform(a: t.a, b: t.b, c: t.c, d: t.d, tx: t.e, ty: t.f)
        return MeshWarp.placeSource(src, srcRect: bounds, transform: a, warp: w, on: .cpu)
    }

    /// Extensions PCIO reads as layered documents (everything else is a flat image). A `.comp` is a Compositor package
    /// (a folder), opened read-only.
    public static let layeredExtensions: Set<String> = ["psd", "psb", "pcraft", "ora", "kra", "pdn", "tif", "tiff", "exr", "svg", "svgz",
                                                        "af", "afdesign", "afphoto", "afpub", "comp"]

    /// Extensions PCIO itself writes (the rest go through `ImageCodecs`).
    static let pcioWrites: Set<String> = ["psd", "psb", "pcraft", "ora", "png", "jpg", "jpeg", "tif", "tiff"]

    /// Import-only formats PCIO refuses to write, with the reason.
    static let pcioRefuses: Set<String> = ["pdn", "af", "afdesign", "afphoto", "afpub"]

    /// The lower-case extension of the file name in `path` (photocraft `file_cmds::extension`).
    public static func fileExtension(_ path: String) -> String? {
        let name = DocState.fileName(path)
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return nil }
        let ext = name[name.index(after: dot)...]
        return ext.isEmpty ? nil : ext.lowercased()
    }

    /// Whether a lower-case extension names a layered document format (PSD, PSB, OpenRaster,
    /// .pcraft): a save to one becomes the document's file (photocraft `layered_extension`).
    public static func layeredExtension(_ ext: String) -> Bool { ["psd", "psb", "pcraft", "ora"].contains(ext) }

    /// Whether a save without a new path may write back to `path` (photocraft `saves_in_place`).
    public static func savesInPlace(_ path: String) -> Bool { fileExtension(path).map(layeredExtension) ?? false }

    /// Imports `bytes` named `name` into a document (photocraft `file_cmds::import`).
    public static func importFile(name: String, bytes: [UInt8], services: EngineServices, interrupt: Interrupt = .none) throws -> ImportResult {
        var r: ImportResult
        do { r = try DocumentIO.importFile(name: name, bytes: bytes, options: options(services, interrupt: interrupt)) } catch {
            throw wrap(error, "open `\(name)`")
        }
        // PCIO's flat import records `Document.fileEncoding` (photocraft `io::flat`), a lossy WebP
        // with photocraft's default quality (75): PCIO doesn't link PCPlatform, whose
        // `SourceSettings.webpQuality` reads the file's own libwebp quality (±1) back.
        if r.document.fileEncoding.webpLossless == false, let q = SourceSettings.webpQuality(Data(bytes)) {
            r.document.fileEncoding.webpQuality = UInt8(clamping: q)
        }
        return r
    }

    /// Reads and imports the file at `path` through the session's file service. A `.pcraft`
    /// package (a folder) is read object by object, a local single-file `.pcraft` entry by entry, and a
    /// Compositor `.comp` package (a folder) by PCIO's `DocumentIO.importFile(contentsOf:)`.
    public static func importPath(_ path: String, services: EngineServices, interrupt: Interrupt = .none) throws -> ImportResult {
        let fs = services.fileSystem
        if fileExtension(path) == PcraftFormat.fileExtension, fs.isDirectory(path) {
            guard let url = fs.localURL(path) else { throw EngineError.other("read `\(path)`: .pcraft packages can't be opened here") }
            do {
                var doc = try PcraftFormat.load(contentsOf: url)
                doc.name = DocState.fileName(path)
                return ImportResult(document: doc)
            } catch {
                throw EngineError.other("open `\(DocState.fileName(path))`: pcraft: \(error)")
            }
        }
        // A Compositor `.comp` package (a folder; import-only, AB-D-0131) goes to PCIO's reader of packages on disk,
        // read-only, with the manifest's guides and layer ids (`ImportResult.sourceLayerIds`) (AB-T-0323).
        if fileExtension(path) == CompImport.fileExtension, fs.isDirectory(path) {
            guard let url = fs.localURL(path) else { throw EngineError.other("read `\(path)`: .comp packages can't be opened here") }
            do {
                var r = try DocumentIO.importFile(contentsOf: url, options: options(services, interrupt: interrupt))
                r.document.name = DocState.fileName(path)
                return r
            } catch {
                throw wrap(error, "open `\(DocState.fileName(path))`")
            }
        }
        // A single-file `.pcraft` on a local disk is read entry by entry, never whole (AB-T-0249).
        if fileExtension(path) == PcraftFormat.fileExtension, fs.exists(path), let url = fs.localURL(path) {
            do { return try DocumentIO.importFile(contentsOf: url, options: options(services, interrupt: interrupt)) } catch {
                throw wrap(error, "open `\(DocState.fileName(path))`")
            }
        }
        let data: Data
        do { data = try services.fileSystem.read(path) } catch { throw EngineError.other("read `\(path)`: \(EngineError.wrap(error))") }
        return try importFile(name: DocState.fileName(path), bytes: [UInt8](data), services: services, interrupt: interrupt)
    }

    /// Encodes `doc` for `nameOrExt` (a file name, path or extension): PCIO for the layered formats
    /// and PNG/JPEG/TIFF, PCPlatform's codecs for every other flat format (photocraft `save_doc`'s
    /// encoder half). `quality` is JPEG/lossy quality 1…100.
    public static func export(_ doc: Document, as nameOrExt: String, services: EngineServices, quality: Double? = nil,
                              tiffLayers: Bool = false, imagePreviews: Bool = true, tgaBits: Int? = nil, interrupt: Interrupt = .none) throws -> ExportResult {
        let ext = nameOrExt.contains(".") || nameOrExt.contains("/") ? (fileExtension(nameOrExt) ?? "") : nameOrExt.lowercased()
        // No quality chosen: a JPEG keeps the quality its file was opened at (photocraft
        // `apply_file_encoding`), as Photoshop's Save does.
        let jpeg = quality ?? doc.fileEncoding.jpegQuality.map { Double(min(max($0, 1), 100)) }
        // PCIO also refuses the import-only formats (Paint.NET, Affinity) with its own message.
        if pcioWrites.contains(ext) || pcioRefuses.contains(ext) || ext == "psdt" {
            var o = options(services, interrupt: interrupt, jpegQuality: jpeg.map { min(max($0, 1), 100) / 100 })
            o.tiffLayers = tiffLayers
            o.imagePreviews = imagePreviews
            do {
                return try DocumentIO.export(doc, as: ext == "psdt" ? "psd" : ext, options: o)
            } catch let e as EngineError { throw e } catch { throw wrap(error, "save `\(nameOrExt)`") }
        }
        guard let fmt = ImageFormat.from(extension: ext) else { throw EngineError.other("unknown file format `\(ext)`") }
        return try flatExport(doc, fmt, services: services, quality: quality, tgaBits: tgaBits)
    }

    /// The composite encoded by `ImageCodecs` (formats PCIO leaves to the codec layer).
    static func flatExport(_ doc: Document, _ fmt: ImageFormat, services: EngineServices, quality: Double?, tgaBits: Int? = nil) throws -> ExportResult {
        let pf = doc.pixelFormat
        let target = PixelFormat(mode: pf.mode == .grayscale ? .grayscale : .rgb, sample: pf.sample, alpha: true)
        var surface = try services.renderer.compositeToSurface(doc, rect: doc.bounds, format: target)
        if fmt == .tga { surface = targa(surface, doc, bits: tgaBits) }
        var o = EncodeOptions()
        // A WebP is written lossy or lossless the way its file was opened, unless a quality asks
        // for the lossy encoder (photocraft `apply_file_encoding` / `save_doc`).
        let e = doc.fileEncoding
        if let lossless = e.webpLossless { o.webpLossless = lossless }
        if let q = e.webpQuality { o.webpQuality = Int(min(q, 100)) }
        if let q = e.jpegQuality { o.jpegQuality = Int(min(max(q, 1), 100)) }
        if let q = quality {
            o.jpegQuality = Int(min(max(q, 0), 100)); o.lossyQuality = min(max(q / 100, 0), 1); o.webpQuality = Int(min(max(q, 0), 100))
            o.webpLossless = false
        }
        let profile = doc.iccProfile.flatMap { try? ICCProfile(data: Data($0)) }
        let warnings = ImageCodecs.fidelityWarnings(for: surface.format, width: doc.size.width, height: doc.size.height, as: fmt).map(\.description)
        do {
            let data = try ImageCodecs.encode(surface, rect: doc.bounds, as: fmt, profile: profile, metadata: nil, options: o)
            return ExportResult(bytes: [UInt8](data), warnings: warnings)
        } catch {
            throw EngineError.other("save as \(fmt.name): \(error)")
        }
    }

    /// The Targa pixels for `bits` (photocraft-io `TgaBits`): 32 writes the document's first alpha
    /// channel, or else the transparency, as the alpha; 24 drops it; unset, 32 when there is an
    /// alpha channel or transparency, else 24.
    static func targa(_ composite: Surface, _ doc: Document, bits: Int?) -> Surface {
        let r = doc.bounds
        let fmt = composite.format
        let ch = fmt.channels
        var px = composite.readRegion(r)
        let transparent = stride(from: ch - 1, to: px.count, by: ch).contains { px[$0] < 1 }
        let alphaChannel = doc.channels.first?.surface
        let want = bits ?? (alphaChannel != nil || transparent ? 32 : 24)
        if want == 32 {
            if let a = alphaChannel {
                let cov = a.coverage(r)
                for i in 0..<r.area { px[i * ch + ch - 1] = cov[i] }
            }
            var out = Surface(format: fmt)
            out.writeRegion(r, px)
            return out
        }
        let opaque = fmt.with(alpha: false)
        var flat = [Float](repeating: 0, count: r.area * (ch - 1))
        for i in 0..<r.area { for c in 0..<(ch - 1) { flat[i * (ch - 1) + c] = px[i * ch + c] } }
        var out = Surface(format: opaque)
        out.writeRegion(r, flat)
        return out
    }

    static func wrap(_ error: any Error, _ what: String) -> EngineError {
        if let e = error as? EngineError { return e }
        if let e = error as? PCIOError {
            if case .cancelled = e { return .cancelled }
            return .other("\(what): \(e)")
        }
        return .other("\(what): \(error)")
    }
}
