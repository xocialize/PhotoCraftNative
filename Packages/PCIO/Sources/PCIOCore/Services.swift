// The services PCIO needs but must not implement itself, injected by the engine:
//
// * `DocumentCompositor` — the merged composite of a document. photocraft's rule (architecture
//   §8): psd/io never composites; the export's merged image comes from the compositor
//   (`photocraft_compose::render_bands` / `flatten` / `thumbnail` in photocraft, PCRender here).
// * `LayerContentRenderer` — rendering of model-only layers (type without pixels, shapes without
//   pixels, fill layers whose Photoshop rendering went stale), photocraft's `photocraft_text`,
//   `photocraft_vector::render_shape` and `photocraft_compose::render_fill_content`.
// * `FlatImageCodec` — the flat images inside containers (OpenRaster/Krita PNGs, `.pcraft`
//   previews, PSD thumbnails), photocraft-codecs. A default ImageIO implementation is provided;
//   the engine can inject PCPlatform's `ImageCodecs` instead.
//
// API shape ported from photocraft-io (crates/io/src/lib.rs, psd_export.rs, psd_import.rs,
// text_import.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import CoreGraphics
import Foundation
import ImageIO
import PCDocument
import PCFoundation
import UniformTypeIdentifiers

// MARK: - Compositor

/// Renders a document's merged composite. The engine wires PCRender in.
public protocol DocumentCompositor: Sendable {
    /// The composite of `document` over `rect` (document pixels), row-major, as interleaved
    /// normalised samples in `document.pixelFormat`: the colour channels of the document's storage
    /// model (CMYK as ink 0...1, Lab as stored 0...1, Gray, RGB) followed by alpha; straight (not
    /// premultiplied) and not matted. Photoshop's merged image of the whole canvas.
    func composite(_ document: Document, rect: PixelRect) throws -> [Float]

    /// The whole canvas area-averaged (premultiplied) to `width` × `height` (at most the canvas),
    /// row-major straight RGBA: the composite's samples as `Surface.readRGBA` reads them (RGB and
    /// Gray as they are, CMYK and Lab converted). Output column `x` averages canvas columns
    /// `x·W/width ..< (x+1)·W/width`, rounded down, and rows likewise (PCRender's
    /// `renderReduced`). The `.pcraft` previews. The default composites a band at a time through
    /// `composite(_:rect:)` (`ReducedComposite`).
    func reduced(_ document: Document, width: Int, height: Int) throws -> [SIMD4<Float>]

    /// `reduced` for only the output pixels whose canvas spans meet `damage`: their rect, in
    /// output pixels from (0, 0) (empty when `damage` misses the canvas), and their pixels, with
    /// the values the whole reduction gives them. A preview kept from an earlier save is updated
    /// with it where an edit can have changed the composite. The default reduces the whole canvas.
    func reduced(_ document: Document, width: Int, height: Int, damage: PixelRect) throws -> (rect: PixelRect, pixels: [SIMD4<Float>])

    /// A filter adjustment layer (`Adjustment.filter`) baked to pixels, for a container with no live
    /// form of it (PSD/PSB, AB-D-0143): the filter applied to the layer's backdrop as this
    /// compositor evaluates the layer, in `document.pixelFormat`, written so that the pixels
    /// composited with the layer's own mask, opacity, blend mode and clipping give the live layer's
    /// result. nil: this compositor can't (the default); the layer is then written empty.
    func bakeFilterLayer(_ document: Document, layer: LayerId) throws -> Surface?
}

extension DocumentCompositor {
    public func bakeFilterLayer(_ document: Document, layer: LayerId) throws -> Surface? { nil }
}

/// A compositor from a closure producing straight sRGB RGBA (photocraft `render_bands`' output),
/// converted into the document's model with `PixelFormat.components(fromRGBA:)` as photocraft
/// does (`from_rgba_into`).
public struct RGBACompositor: DocumentCompositor {
    public let render: @Sendable (Document, PixelRect) throws -> [SIMD4<Float>]

    public init(_ render: @escaping @Sendable (Document, PixelRect) throws -> [SIMD4<Float>]) { self.render = render }

    public func composite(_ document: Document, rect: PixelRect) throws -> [Float] {
        let fmt = document.pixelFormat
        let px = try render(document, rect)
        guard px.count == rect.area else { throw PCIOError.codec("compositor returned \(px.count) pixels for \(rect.area)") }
        var out: [Float] = []
        out.reserveCapacity(px.count * fmt.channels)
        for p in px { out += fmt.components(fromRGBA: p) }
        return out
    }
}

/// A compositor returning fixed pixels for the whole canvas (tests; re-saving a document whose
/// composite the caller already has).
public struct FixedCompositor: DocumentCompositor {
    /// Interleaved samples of the full canvas in the document's pixel format.
    public let pixels: [Float]
    public let size: PixelSize

    public init(pixels: [Float], size: PixelSize) { self.pixels = pixels; self.size = size }

    public func composite(_ document: Document, rect: PixelRect) throws -> [Float] {
        let ch = document.pixelFormat.channels
        guard size == document.size, pixels.count == size.width * size.height * ch else {
            throw PCIOError.codec("fixed composite does not match the document")
        }
        let canvas = PixelRect(size: size)
        let r = rect.intersect(canvas)
        var out = [Float](repeating: 0, count: rect.area * ch)
        if r.isEmpty { return out }
        for y in r.y0 ..< r.y1 {
            let src = (Int(y) * size.width + Int(r.x0)) * ch
            let dst = (Int(y - rect.y0) * rect.width + Int(r.x0 - rect.x0)) * ch
            out.replaceSubrange(dst ..< dst + r.width * ch, with: pixels[src ..< src + r.width * ch])
        }
        return out
    }
}

/// The compositor used when none is injected: stacks the stored pixels of visible raster-like
/// layers with Normal blending and layer opacity (no effects, adjustments, masks or modes). Only
/// good enough for tests and previews of simple documents; the engine injects PCRender.
public struct StoredPixelsCompositor: DocumentCompositor {
    public init() {}

    public func composite(_ document: Document, rect: PixelRect) throws -> [Float] {
        let fmt = document.pixelFormat
        let ch = fmt.channels
        let cc = ch - 1
        var out = [Float](repeating: 0, count: rect.area * ch)
        func visit(_ layers: [Layer], _ opacity: Float) {
            for l in layers where l.visible {
                if let g = l.group {
                    visit(g.children, opacity * l.opacity)
                    continue
                }
                guard let s = l.surface ?? l.fillCache?.surface else { continue }
                let src = s.format == fmt ? s : nil
                guard let src else { continue }
                let vals = src.readRegion(rect)
                let a0 = opacity * l.opacity * l.fillOpacity
                for i in 0 ..< rect.area {
                    let sa = vals[i * ch + cc] * a0
                    if sa <= 0 { continue }
                    let da = out[i * ch + cc]
                    let oa = sa + da * (1 - sa)
                    for c in 0 ..< cc {
                        out[i * ch + c] = oa > 0 ? (vals[i * ch + c] * sa + out[i * ch + c] * da * (1 - sa)) / oa : 0
                    }
                    out[i * ch + cc] = oa
                }
            }
        }
        visit(document.layers, 1)
        return out
    }
}

// MARK: - Layer content renderer

/// A font face a PostScript name resolves to (photocraft `fonts.resolve_postscript`).
public struct ResolvedFont: Sendable, Hashable {
    public var family: String
    public var weight: UInt16
    public var italic: Bool
    /// The name matched an installed face exactly.
    public var exact: Bool
    public init(family: String, weight: UInt16, italic: Bool, exact: Bool) {
        self.family = family; self.weight = weight; self.italic = italic; self.exact = exact
    }
}

/// Builds the CMYK converter of an ICC profile (a document's own CMYK profile), e.g.
/// PCPlatform's ColorSync one. Import and export of a CMYK document run inside
/// `ColorConvert.withCMYK` with it (photocraft `with_cmyk_space`), so colours are separated and
/// read through the document's profile rather than the process-wide one. nil: the process-wide
/// conversion.
public typealias CMYKConverterFactory = @Sendable (_ iccProfile: [UInt8]) -> (any CMYKConverter)?

/// Renders layers whose pixels exist only as a model. Every method may return nil ("can't"),
/// in which case the importer/exporter keeps empty pixels and warns, as photocraft does when
/// its renderers refuse.
public protocol LayerContentRenderer: Sendable {
    /// A shape layer's pixels on `canvas` in `format` (photocraft `photocraft_vector::render_shape`).
    func renderShape(_ shape: ShapeLayer, format: PixelFormat, canvas: PixelRect) -> Surface?
    /// A type layer's pixels in document coordinates (photocraft `text_import::render_bounded`):
    /// nil when its ink would exceed `maxPixels`.
    func renderText(_ text: TextLayer, format: PixelFormat, dpi: Float, maxPixels: UInt64) -> Surface?
    /// A fill layer's pixels on `canvas` in `format`, framed by the layer's masks like the
    /// compositor (photocraft `render_fill_content`, `render_cmyk_fill`).
    func renderFill(_ layer: Layer, fill: Fill, canvas: PixelRect, patterns: [Pattern], format: PixelFormat) -> Surface?
    /// Whether `family` is installed.
    func hasFontFamily(_ family: String) -> Bool
    /// The installed face a PostScript name resolves to.
    func resolvePostScript(_ name: String) -> ResolvedFont?
}

extension LayerContentRenderer {
    public func renderShape(_ shape: ShapeLayer, format: PixelFormat, canvas: PixelRect) -> Surface? { nil }
    public func renderText(_ text: TextLayer, format: PixelFormat, dpi: Float, maxPixels: UInt64) -> Surface? { nil }
    public func renderFill(_ layer: Layer, fill: Fill, canvas: PixelRect, patterns: [Pattern], format: PixelFormat) -> Surface? { nil }
    public func hasFontFamily(_ family: String) -> Bool { true }
    public func resolvePostScript(_ name: String) -> ResolvedFont? { nil }
}

/// Renders nothing (the default when no renderer is injected).
public struct NoContentRenderer: LayerContentRenderer {
    public init() {}
}

// MARK: - Flat image codec

/// A decoded flat image in a document storage format.
public struct DecodedImage: Sendable {
    /// The pixels at (0, 0)–(width, height): Gray, RGB or CMYK at 8/16/32-bit, always with alpha
    /// (straight, not premultiplied), as stored: `orientation` has not been applied.
    public var surface: Surface
    public var width: Int
    public var height: Int
    /// Whether the file carried an alpha channel.
    public var hasAlpha: Bool
    public var iccProfile: [UInt8]?
    /// Horizontal and vertical resolution in pixels per inch, when stored.
    public var dpi: (x: Double, y: Double)?
    /// Raw EXIF in TIFF structure (`II*\0` / `MM\0*`), without a JPEG `Exif\0\0` prefix.
    public var exif: [UInt8]?
    /// The XMP packet.
    public var xmp: String?
    /// Free-form text (PNG tEXt/zTXt/iTXt, TIFF ASCII tags), in file order.
    public var text: [MetadataText]
    /// The stored EXIF/TIFF orientation (1–8) the pixels still need turning by; 1 = upright.
    public var orientation: Int
    /// The file stored 16-bit floats (decoded to 32-bit).
    public var halfFloat: Bool
    /// What the decoder noticed that the pixels don't show (frames or pages left out, data
    /// ending early), photocraft-codecs' `DecodeWarning` texts.
    public var warnings: [String]

    public init(surface: Surface, width: Int, height: Int, hasAlpha: Bool, iccProfile: [UInt8]? = nil, dpi: (x: Double, y: Double)? = nil,
                exif: [UInt8]? = nil, xmp: String? = nil, text: [MetadataText] = [], orientation: Int = 1, halfFloat: Bool = false,
                warnings: [String] = []) {
        self.surface = surface; self.width = width; self.height = height; self.hasAlpha = hasAlpha
        self.iccProfile = iccProfile; self.dpi = dpi
        self.exif = exif; self.xmp = xmp; self.text = text; self.orientation = orientation; self.halfFloat = halfFloat
        self.warnings = warnings
    }
}

/// Flat image formats PCIO writes inside containers.
public enum FlatImageType: String, Sendable, CaseIterable {
    case png, jpeg, tiff
}

/// Decodes and encodes the flat images inside containers.
public protocol FlatImageCodec: Sendable {
    func decode(_ data: [UInt8]) throws -> DecodedImage
    /// Encodes `rect` of `surface` (Gray/RGB/CMYK at its own depth, with or without alpha).
    func encode(_ surface: Surface, rect: PixelRect, as type: FlatImageType, quality: Double?, iccProfile: [UInt8]?) throws -> [UInt8]
    /// `encode` with the file's metadata (already normalised for a flat file: EXIF in TIFF
    /// structure, XMP, free-form text) and resolution. The default leaves them out.
    func encode(_ surface: Surface, rect: PixelRect, as type: FlatImageType, quality: Double?, iccProfile: [UInt8]?,
                metadata: FlatMetadata.Metadata, dpi: Double?) throws -> [UInt8]
}

extension FlatImageCodec {
    public func encode(_ surface: Surface, rect: PixelRect, as type: FlatImageType, quality: Double?, iccProfile: [UInt8]?,
                       metadata: FlatMetadata.Metadata, dpi: Double?) throws -> [UInt8] {
        try encode(surface, rect: rect, as: type, quality: quality, iccProfile: iccProfile)
    }
}

/// `FlatImageCodec` on ImageIO at native depth (8/16-bit and float; Gray/RGB/CMYK).
public struct ImageIOCodec: FlatImageCodec {
    public init() {}

    public func decode(_ data: [UInt8]) throws -> DecodedImage {
        guard let src = CGImageSourceCreateWithData(Data(data) as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(src) > 0,
              let img = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldAllowFloat: true] as CFDictionary) else {
            throw PCIOError.codec("unreadable image")
        }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        var dpi: (x: Double, y: Double)?
        if let x = props?[kCGImagePropertyDPIWidth] as? Double, let y = props?[kCGImagePropertyDPIHeight] as? Double, x > 0, y > 0, x.isFinite, y.isFinite {
            dpi = (x, y)
        }
        let orientation = (props?[kCGImagePropertyOrientation] as? Int).flatMap { (1 ... 8).contains($0) ? $0 : nil } ?? 1
        let alphaInfo = img.alphaInfo
        let hasAlpha = !(alphaInfo == .none || alphaInfo == .noneSkipFirst || alphaInfo == .noneSkipLast)
        let meta = FlatMetadata.read(data)
        // A PNG's resolution from `pHYs` in whole ppi (AB-D-0156), and none without one.
        if FlatMetadata.formatName(data) == "PNG" { dpi = meta.dpi.map { ($0.x, $0.y) } }
        // The profile as the file stores it (CoreGraphics re-serialises profiles and invents one
        // for untagged files); CoreGraphics' only for containers not read here.
        let icc = meta.container ? meta.icc : img.colorSpace?.copyICCData().map { [UInt8]($0 as Data) }
        var warnings: [String] = []
        let count = CGImageSourceGetCount(src)
        let name = FlatMetadata.formatName(data)
        if count > 1 {
            warnings.append(name == "TIFF" ? "only the first of \(count) pages was imported" : "only the first of \(count) frames was imported")
        }
        if meta.truncated || CGImageSourceGetStatusAtIndex(src, 0) == .statusIncomplete || CGImageSourceGetStatus(src) == .statusIncomplete {
            warnings.append("\(name ?? "image") data ends early (the file is truncated or damaged); part of the image is missing")
        }
        let surface: Surface
        var half = false
        if let raw = ImageIOCodec.storedSurface(img) {
            surface = raw.surface
            half = raw.half
        } else {
            let model = img.colorSpace?.model ?? .rgb
            let mode: ColorMode = model == .monochrome ? .grayscale : model == .cmyk ? .cmyk : .rgb
            let floats = img.bitmapInfo.contains(.floatComponents)
            half = floats && img.bitsPerComponent == 16
            let sample: SampleType = floats ? .f32 : (img.bitsPerComponent > 8 ? .u16 : .u8)
            surface = try ImageIOCodec.surface(from: img, mode: mode, sample: sample)
        }
        // Containers the reader doesn't parse (HEIC/HEIF, …): EXIF and XMP as ImageIO exposes them.
        var exif = meta.exif, xmp = meta.xmp
        if !meta.container {
            if exif == nil, let props { exif = ImageIOCodec.exifBytes(props, width: img.width, height: img.height) }
            if xmp == nil { xmp = ImageIOCodec.xmpPacket(src) }
        }
        return DecodedImage(surface: surface, width: img.width, height: img.height, hasAlpha: hasAlpha, iccProfile: icc, dpi: dpi,
                            exif: exif, xmp: xmp, text: meta.text, orientation: orientation, halfFloat: half, warnings: warnings)
    }

    /// The EXIF of image properties as a TIFF-structured EXIF block (what a JPEG's APP1 carries):
    /// ImageIO serialises it into a one-pixel JPEG, whose APP1 is read back. nil without EXIF.
    static func exifBytes(_ props: [CFString: Any], width: Int, height: Int) -> [UInt8]? {
        guard var exifDict = props[kCGImagePropertyExifDictionary] as? [CFString: Any] else { return nil }
        // The real image's size, not the stand-in pixel's.
        exifDict[kCGImagePropertyExifPixelXDimension] = width
        exifDict[kCGImagePropertyExifPixelYDimension] = height
        var p: [CFString: Any] = [kCGImagePropertyExifDictionary: exifDict]
        for k in [kCGImagePropertyTIFFDictionary, kCGImagePropertyGPSDictionary, kCGImagePropertyOrientation] { if let v = props[k] { p[k] = v } }
        guard let provider = CGDataProvider(data: Data([0x80]) as CFData),
              let pixel = CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: 1, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider, decode: nil,
                                  shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        let out = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(out as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dst, pixel, p as CFDictionary)
        guard CGImageDestinationFinalize(dst) else { return nil }
        return FlatMetadata.read([UInt8](out as Data)).exif
    }

    /// The image's XMP packet when it holds more than the EXIF/TIFF properties ImageIO mirrors
    /// into XMP form.
    static func xmpPacket(_ src: CGImageSource) -> String? {
        guard let meta = CGImageSourceCopyMetadataAtIndex(src, 0, nil),
              let tags = CGImageMetadataCopyTags(meta) as? [CGImageMetadataTag] else { return nil }
        let mirrored: Set<String> = ["exif", "exifEX", "tiff", "aux"]
        guard tags.contains(where: { CGImageMetadataTagCopyPrefix($0).map { !mirrored.contains($0 as String) } ?? true }),
              let data = CGImageMetadataCreateXMPData(meta, nil) else { return nil }
        return String(decoding: data as Data, as: UTF8.self)
    }

    /// The image's own samples, read from its data provider without drawing (drawing
    /// premultiplies, which loses straight-alpha colour, and has no Gray + alpha format): Gray,
    /// RGB or CMYK at 8/16-bit integer or 16/32-bit float, any alpha placement and byte order.
    /// nil for any other layout (indexed, Lab, decode arrays, packed formats), which is drawn.
    static func storedSurface(_ img: CGImage) -> (surface: Surface, half: Bool)? {
        guard img.decode == nil, let space = img.colorSpace else { return nil }
        let mode: ColorMode
        switch space.model {
        case .monochrome: mode = .grayscale
        case .rgb: mode = .rgb
        case .cmyk: mode = .cmyk
        default: return nil
        }
        let cc = mode.colorChannels
        guard space.numberOfComponents == cc else { return nil }
        // (has alpha, padding component, alpha/padding first, premultiplied)
        let layout: (alpha: Bool, skip: Bool, first: Bool, premultiplied: Bool)
        switch img.alphaInfo {
        case .none: layout = (false, false, false, false)
        case .last: layout = (true, false, false, false)
        case .first: layout = (true, false, true, false)
        case .premultipliedLast: layout = (true, false, false, true)
        case .premultipliedFirst: layout = (true, false, true, true)
        case .noneSkipLast: layout = (false, true, false, false)
        case .noneSkipFirst: layout = (false, true, true, false)
        default: return nil
        }
        let comps = cc + (layout.alpha || layout.skip ? 1 : 0)
        let bpc = img.bitsPerComponent
        let float = img.bitmapInfo.contains(.floatComponents)
        guard img.bitsPerPixel == bpc * comps, (float && (bpc == 16 || bpc == 32)) || (!float && (bpc == 8 || bpc == 16)) else { return nil }
        let w = img.width, h = img.height
        let pixelBytes = bpc * comps / 8
        guard w > 0, h > 0, img.bytesPerRow >= w * pixelBytes else { return nil }
        // Component byte order, and 8-bit pixels stored as one little-endian word (BGRA).
        let order = img.byteOrderInfo
        var little = false
        var reversedWord = false
        switch (bpc, order) {
        case (8, .orderDefault), (8, .order32Big), (8, .order16Big): break
        case (8, .order32Little): guard pixelBytes == 4 else { return nil }; reversedWord = true
        case (8, .order16Little): guard pixelBytes == 2 else { return nil }; reversedWord = true
        case (16, .orderDefault), (16, .order16Big): break
        case (16, .order16Little): little = true
        case (32, .orderDefault), (32, .order32Big): break
        case (32, .order32Little): little = true
        default: return nil
        }
        guard let cf = img.dataProvider?.data else { return nil }
        let data = cf as Data
        guard data.count >= img.bytesPerRow * (h - 1) + w * pixelBytes else { return nil }
        let sample: SampleType = float ? .f32 : (bpc == 16 ? .u16 : .u8)
        let fmt = PixelFormat(mode: mode, sample: sample, alpha: true)
        var surface = Surface(format: fmt)
        let rowBytes = img.bytesPerRow
        let bandRows = max(1, (8 << 20) / max(1, w * (cc + 1) * 4))
        var px = [Float](repeating: 0, count: comps)
        data.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
            var y0 = 0
            while y0 < h {
                let y1 = min(h, y0 + bandRows)
                var vals = [Float](repeating: 0, count: (y1 - y0) * w * (cc + 1))
                var o = 0
                for y in y0 ..< y1 {
                    let row = y * rowBytes
                    for x in 0 ..< w {
                        let at = row + x * pixelBytes
                        for c in 0 ..< comps {
                            let k = reversedWord ? comps - 1 - c : c
                            switch (bpc, float) {
                            case (8, _): px[c] = Float(p[at + k]) / 255
                            case (16, false):
                                let v = UInt16(p[at + 2 * c]) << 8 | UInt16(p[at + 2 * c + 1])
                                px[c] = Float(little ? v.byteSwapped : v) / 65535
                            case (16, true):
                                let v = UInt16(p[at + 2 * c]) << 8 | UInt16(p[at + 2 * c + 1])
                                px[c] = Float(Float16(bitPattern: little ? v.byteSwapped : v))
                            default:
                                var v: UInt32 = 0
                                for b in 0 ..< 4 { v = v << 8 | UInt32(p[at + 4 * c + b]) }
                                px[c] = Float(bitPattern: little ? v.byteSwapped : v)
                            }
                        }
                        let colour = layout.first ? 1 : 0
                        let a: Float = layout.alpha ? px[layout.first ? 0 : cc] : 1
                        for c in 0 ..< cc {
                            let v = px[colour + c]
                            vals[o + c] = layout.premultiplied ? (a > 0 ? (float ? v / a : min(v / a, 1)) : 0) : v
                        }
                        vals[o + cc] = a
                        o += cc + 1
                    }
                }
                surface.writeRegion(PixelRect(x0: 0, y0: Int32(y0), x1: Int32(w), y1: Int32(y1)), vals)
                y0 = y1
            }
        }
        surface.prune()
        return (surface, float && bpc == 16)
    }

    /// Draws `img` into a straight-alpha buffer of the target model and depth (the layouts
    /// `storedSurface` can't read).
    static func surface(from img: CGImage, mode: ColorMode, sample: SampleType) throws -> Surface {
        let w = img.width, h = img.height
        let fmt = PixelFormat(mode: mode, sample: sample, alpha: true)
        var surface = Surface(format: fmt)
        guard w > 0, h > 0 else { return surface }
        // CoreGraphics draws premultiplied, and Gray and CMYK contexts cannot carry alpha: those
        // draw the colour over zero (premultiplied too) and the alpha separately.
        let cc = mode.colorChannels
        let space: CGColorSpace
        switch mode {
        case .grayscale: space = img.colorSpace.flatMap { $0.model == .monochrome ? $0 : nil } ?? CGColorSpaceCreateDeviceGray()
        case .cmyk: space = img.colorSpace.flatMap { $0.model == .cmyk ? $0 : nil } ?? CGColorSpaceCreateDeviceCMYK()
        default: space = img.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        }
        let floatBuf = sample == .f32
        let bpc = floatBuf ? 32 : (sample == .u16 ? 16 : 8)
        let separateAlpha = mode != .rgb
        let comps = separateAlpha ? cc : cc + 1
        let rowBytes = w * comps * bpc / 8
        var buf = [UInt8](repeating: 0, count: rowBytes * h)
        var info = separateAlpha ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue
        if floatBuf { info |= CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue }
        else if bpc == 16 { info |= CGBitmapInfo.byteOrder16Little.rawValue }
        let ok = buf.withUnsafeMutableBytes { p -> Bool in
            guard let ctx = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: bpc, bytesPerRow: rowBytes, space: space, bitmapInfo: info) else { return false }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { throw PCIOError.codec("cannot draw a \(mode) \(bpc)-bit image") }
        let alpha = separateAlpha ? try ImageIOCodec.alphaPlane(img) : nil
        var vals = [Float](repeating: 0, count: w * h * (cc + 1))
        buf.withUnsafeBytes { p in
            var px = [Float](repeating: 0, count: comps)
            for i in 0 ..< w * h {
                for c in 0 ..< comps {
                    let at = i * comps + c
                    switch bpc {
                    case 32: px[c] = p.loadUnaligned(fromByteOffset: at * 4, as: Float.self)
                    case 16: px[c] = Float(p.loadUnaligned(fromByteOffset: at * 2, as: UInt16.self)) / 65535
                    default: px[c] = Float(p[at]) / 255
                    }
                }
                let a = separateAlpha ? (alpha?[i] ?? 1) : px[cc]
                for c in 0 ..< cc { vals[i * (cc + 1) + c] = a > 0 ? min(px[c] / a, floatBuf ? .greatestFiniteMagnitude : 1) : 0 }
                vals[i * (cc + 1) + cc] = a
            }
        }
        surface.writeRegion(PixelRect(x0: 0, y0: 0, x1: Int32(w), y1: Int32(h)), vals)
        surface.prune()
        return surface
    }

    /// The alpha of an image (all ones without alpha).
    static func alphaPlane(_ img: CGImage) throws -> [Float]? {
        let info = img.alphaInfo
        if info == .none || info == .noneSkipFirst || info == .noneSkipLast { return nil }
        let w = img.width, h = img.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let ok = buf.withUnsafeMutableBytes { p -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let ctx = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        return (0 ..< w * h).map { Float(buf[$0 * 4 + 3]) / 255 }
    }

    public func encode(_ surface: Surface, rect: PixelRect, as type: FlatImageType, quality: Double?, iccProfile: [UInt8]?) throws -> [UInt8] {
        try encode(surface, rect: rect, as: type, quality: quality, iccProfile: iccProfile, metadata: FlatMetadata.Metadata(), dpi: nil)
    }

    /// Writes the resolution through ImageIO (PNG `pHYs`, JFIF density, TIFF tags), the TIFF text
    /// tags and XMP through ImageIO's metadata, and for PNG and JPEG the EXIF, XMP and text as
    /// photocraft-codecs writes them (`eXIf`, `iTXt` `XML:com.adobe.xmp`, `tEXt`/`iTXt`; APP1
    /// `Exif` and XMP segments, a segment that would outgrow 64 KB left out).
    public func encode(_ surface: Surface, rect: PixelRect, as type: FlatImageType, quality: Double?, iccProfile: [UInt8]?,
                       metadata: FlatMetadata.Metadata, dpi: Double?) throws -> [UInt8] {
        let fmt = surface.format
        let w = rect.width, h = rect.height
        guard w > 0, h > 0 else { throw PCIOError.codec("cannot encode an empty image") }
        let cc = fmt.mode.colorChannels
        let model: ColorMode = fmt.mode == .cmyk ? .cmyk : (cc == 1 ? .grayscale : .rgb)
        let alpha = fmt.alpha && model != .cmyk && type != .jpeg
        let sample: SampleType = type == .jpeg ? .u8 : (fmt.sample == .f32 && type == .png ? .u16 : fmt.sample)
        let bpc = sample.bits
        let comps = (model == .cmyk ? 4 : (model == .grayscale ? 1 : 3)) + (alpha ? 1 : 0)
        let vals = surface.readRegion(rect)
        let ch = fmt.channels
        var bytes = [UInt8](repeating: 0, count: w * h * comps * sample.bytes)
        bytes.withUnsafeMutableBytes { p in
            for i in 0 ..< w * h {
                for c in 0 ..< comps {
                    let srcC = (alpha && c == comps - 1) ? ch - 1 : c
                    // CMYK stays ink (0 = no ink) as CoreGraphics expects; ImageIO applies
                    // the Adobe JPEG inversion itself.
                    writeSample(p, sample, i * comps + c, srcC < ch ? vals[i * ch + srcC] : 1)
                }
            }
        }
        let space: CGColorSpace
        if let icc = iccProfile, let s = CGColorSpace(iccData: Data(icc) as CFData) { space = s }
        else { space = model == .cmyk ? CGColorSpaceCreateDeviceCMYK() : model == .grayscale ? CGColorSpaceCreateDeviceGray() : CGColorSpace(name: CGColorSpace.sRGB)! }
        var info = alpha ? CGImageAlphaInfo.last.rawValue : CGImageAlphaInfo.none.rawValue
        if sample == .f32 { info |= CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue }
        else if sample == .u16 { info |= CGBitmapInfo.byteOrder16Little.rawValue }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let img = CGImage(width: w, height: h, bitsPerComponent: bpc, bitsPerPixel: bpc * comps, bytesPerRow: w * comps * sample.bytes,
                                space: space, bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider, decode: nil,
                                shouldInterpolate: false, intent: .defaultIntent) else {
            throw PCIOError.codec("cannot build a \(bpc)-bit image")
        }
        let uti: UTType = type == .png ? .png : type == .jpeg ? .jpeg : .tiff
        let out = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(out as CFMutableData, uti.identifier as CFString, 1, nil) else {
            throw PCIOError.codec("no \(type.rawValue) encoder")
        }
        var opts: [CFString: Any] = [:]
        if let q = quality { opts[kCGImageDestinationLossyCompressionQuality] = q }
        // ImageIO adds an EXIF block when given a resolution: PNG and JPEG get theirs written here
        // (pHYs, the JFIF density) instead.
        let ppi: Double? = dpi.flatMap { $0 > 0 && $0.isFinite ? $0 : nil }
        if let d = ppi, type == .tiff {
            opts[kCGImagePropertyDPIWidth] = d
            opts[kCGImagePropertyDPIHeight] = d
        }
        if type == .tiff {
            var tiff: [CFString: Any] = [:]
            let keys: [String: CFString] = ["Description": kCGImagePropertyTIFFImageDescription, "Make": kCGImagePropertyTIFFMake,
                                            "Model": kCGImagePropertyTIFFModel, "Software": kCGImagePropertyTIFFSoftware,
                                            "DateTime": kCGImagePropertyTIFFDateTime, "Artist": kCGImagePropertyTIFFArtist,
                                            "Copyright": kCGImagePropertyTIFFCopyright]
            for t in metadata.text { if let k = keys[t.key], tiff[k] == nil { tiff[k] = t.value } }
            if !tiff.isEmpty { opts[kCGImagePropertyTIFFDictionary] = tiff }
        }
        if type == .tiff, let x = metadata.xmp, let meta = CGImageMetadataCreateFromXMPData(Data(x.utf8) as CFData) {
            CGImageDestinationAddImageAndMetadata(dst, img, meta, opts as CFDictionary)
        } else {
            CGImageDestinationAddImage(dst, img, opts as CFDictionary)
        }
        guard CGImageDestinationFinalize(dst) else { throw PCIOError.codec("\(type.rawValue) encoding failed") }
        let encoded = [UInt8](out as Data)
        // PNG and JPEG carry the profile exactly as given (ImageIO re-serialises it, or writes
        // an `sRGB` chunk instead), as photocraft-codecs does.
        let embedded = model == .cmyk && type == .png ? nil : iccProfile
        switch type {
        case .png: return ImageIOCodec.pngWithMetadata(encoded, metadata, ppi: ppi, icc: embedded)
        case .jpeg: return ImageIOCodec.jpegWithMetadata(encoded, metadata, ppi: ppi, icc: embedded)
        case .tiff: return encoded
        }
    }

    /// `png` with `eXIf`, the XMP `iTXt` and the text chunks inserted after `IHDR` (photocraft:
    /// a Latin-1 keyword and text as `tEXt`, other text as uncompressed `iTXt`, other keywords
    /// left out).
    static func pngWithMetadata(_ png: [UInt8], _ m: FlatMetadata.Metadata, ppi: Double? = nil, icc: [UInt8]? = nil) -> [UInt8] {
        let ihdrEnd = 8 + 8 + 13 + 4
        guard png.count >= ihdrEnd else { return png }
        // ImageIO writes an EXIF block (and may write XMP) of its own: only the document's go in.
        var kept: [UInt8] = Array(png[..<ihdrEnd])
        var at = ihdrEnd
        while at + 12 <= png.count {
            let n = Int(FlatMetadata.be32(png, at))
            guard n <= png.count - at - 12 else { kept += png[at...]; at = png.count; break }
            let kind = String(decoding: png[at + 4 ..< at + 8], as: UTF8.self)
            let data = png[at + 8 ..< at + 8 + n]
            let xmp = kind == "iTXt" && data.starts(with: Array(FlatMetadata.xmpKeyword.utf8) + [0])
            // ImageIO's colour chunks give way to the document's own profile.
            let colour = icc != nil && ["iCCP", "sRGB", "gAMA", "cHRM"].contains(kind)
            if kind != "eXIf", !xmp, !colour { kept += png[at ..< at + 12 + n] }
            at += 12 + n
        }
        if at < png.count { kept += png[at...] }
        let png = kept
        func chunk(_ kind: String, _ data: [UInt8]) -> [UInt8] {
            let n = UInt32(clamping: data.count)
            let body = Array(kind.utf8) + data
            let crc = CRC32.checksum(body)
            return [UInt8(n >> 24), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)] + body
                + [UInt8(crc >> 24), UInt8(crc >> 16 & 0xFF), UInt8(crc >> 8 & 0xFF), UInt8(crc & 0xFF)]
        }
        func latin1(_ s: String) -> [UInt8]? {
            var out: [UInt8] = []
            for u in s.unicodeScalars { guard u.value < 256 else { return nil }; out.append(UInt8(u.value)) }
            return out
        }
        func keyword(_ k: String) -> [UInt8]? {
            guard !k.isEmpty, k.unicodeScalars.count <= 79,
                  k.unicodeScalars.allSatisfy({ (0x20 ... 0x7E).contains($0.value) || (0xA1 ... 0xFF).contains($0.value) }) else { return nil }
            return latin1(k)
        }
        var chunks: [UInt8] = []
        if let p = icc, let z = try? Deflate.zlibDeflate(p) { chunks += chunk("iCCP", Array("ICC Profile".utf8) + [0, 0] + z) }
        if let d = ppi {
            // Pixels per metre, unit 1.
            let ppm = UInt32(clamping: Int((d / 0.0254).rounded()))
            let be = [UInt8(ppm >> 24), UInt8(ppm >> 16 & 0xFF), UInt8(ppm >> 8 & 0xFF), UInt8(ppm & 0xFF)]
            chunks += chunk("pHYs", be + be + [1])
        }
        if let e = m.exif { chunks += chunk("eXIf", e) }
        for t in m.text {
            guard let k = keyword(t.key) else { continue }
            if let v = latin1(t.value) {
                chunks += chunk("tEXt", k + [0] + v)
            } else {
                chunks += chunk("iTXt", k + [0, 0, 0, 0, 0] + Array(t.value.utf8))
            }
        }
        if let x = m.xmp { chunks += chunk("iTXt", Array(FlatMetadata.xmpKeyword.utf8) + [0, 0, 0, 0, 0] + Array(x.utf8)) }
        return Array(png[..<ihdrEnd]) + chunks + Array(png[ihdrEnd...])
    }

    /// `jpeg` with the EXIF and XMP APP1 segments after the JFIF header (a segment that doesn't
    /// fit in 64 KB is left out, as photocraft-codecs does).
    static func jpegWithMetadata(_ original: [UInt8], _ m: FlatMetadata.Metadata, ppi: Double? = nil, icc: [UInt8]? = nil) -> [UInt8] {
        guard original.count >= 4, original[0] == 0xFF, original[1] == 0xD8 else { return original }
        // ImageIO writes an EXIF segment (and may write XMP) of its own: only the document's go in.
        var jpeg: [UInt8] = [0xFF, 0xD8]
        var src = 2
        while src + 4 <= original.count, original[src] == 0xFF, (0xE0 ... 0xEF).contains(original[src + 1]) || original[src + 1] == 0xFE {
            let n = Int(original[src + 2]) << 8 | Int(original[src + 3])
            guard n >= 2, src + 2 + n <= original.count else { break }
            let payload = original[(src + 4) ..< (src + 2 + n)]
            let theirs = (original[src + 1] == 0xE1 && (payload.starts(with: FlatMetadata.exifHeader) || payload.starts(with: FlatMetadata.xmpHeader)))
                || (icc != nil && original[src + 1] == 0xE2 && payload.starts(with: FlatMetadata.iccHeader))
            if !theirs { jpeg += original[src ..< src + 2 + n] }
            src += 2 + n
        }
        jpeg += original[src...]
        // After SOI and any APP0 (JFIF), whose density becomes the resolution (dots per inch).
        var at = 2
        while at + 4 <= jpeg.count, jpeg[at] == 0xFF, jpeg[at + 1] == 0xE0 {
            let n = Int(jpeg[at + 2]) << 8 | Int(jpeg[at + 3])
            guard n >= 2, at + 2 + n <= jpeg.count else { break }
            if let d = ppi, n >= 16, Array(jpeg[at + 4 ..< at + 9]) == Array("JFIF\0".utf8) {
                let v = UInt16(clamping: Int(d.rounded()))
                jpeg[at + 11] = 1
                jpeg[at + 12] = UInt8(v >> 8); jpeg[at + 13] = UInt8(v & 0xFF)
                jpeg[at + 14] = UInt8(v >> 8); jpeg[at + 15] = UInt8(v & 0xFF)
            }
            at += 2 + n
        }
        func segment(_ payload: [UInt8]) -> [UInt8]? {
            guard payload.count <= 65533 else { return nil }
            let n = payload.count + 2
            return [0xFF, 0xE1, UInt8(n >> 8), UInt8(n & 0xFF)] + payload
        }
        var segs: [UInt8] = []
        if let e = m.exif, let s = segment(FlatMetadata.exifHeader + e) { segs += s }
        if let x = m.xmp {
            // Too big for one segment: without the layered-document properties (every document
            // ever placed, the text of every type layer), else left out.
            let packet = FlatMetadata.xmpHeader.count + x.utf8.count <= 65533 ? x
                : FlatMetadata.layeredOnlyXMP.reduce(x) { FlatMetadata.removingXMPElement($0, $1) }
            if let s = segment(FlatMetadata.xmpHeader + Array(packet.utf8)) { segs += s }
        }
        if let p = icc, !p.isEmpty {
            // APP2 ICC_PROFILE segments: sequence number (1-based), count, at most 65519 bytes each.
            let size = 65533 - FlatMetadata.iccHeader.count - 2
            let count = (p.count + size - 1) / size
            if count <= 255 {
                for i in 0 ..< count {
                    let part = FlatMetadata.iccHeader + [UInt8(i + 1), UInt8(count)] + Array(p[i * size ..< min(p.count, (i + 1) * size)])
                    let n = part.count + 2
                    segs += [0xFF, 0xE2, UInt8(n >> 8), UInt8(n & 0xFF)] + part
                }
            }
        }
        return Array(jpeg[..<at]) + segs + Array(jpeg[at...])
    }
}
