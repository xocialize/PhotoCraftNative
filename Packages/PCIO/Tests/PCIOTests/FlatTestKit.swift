// Shared helpers of the flat-image, layered-TIFF, metadata and dispatch tests (FlatTests,
// TIFFLayersTests, OrientationTests, …): documents, fixtures written with ImageIO or by hand, the
// compositor, and small TIFF/EXIF/PNG readers and writers.
// Port of photocraft-io (crates/io/tests/{flat,tiff_layers,tiff_pages,orientation,
// exif_resolution,…}.rs helpers; src/{ora,pdn}/tests.rs, kra.rs fixture writers), MIT OR
// Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import CoreGraphics
import Foundation
import ImageIO
import PCDocument
import PCFoundation
import PCIOCore
import PCPSD
import PCRender
import Testing
import UniformTypeIdentifiers
@testable import PCIO
@testable import PCIOFormats

enum FlatKit {
    // MARK: - Compositor and options

    /// The exports' compositor: PCRender's CPU reference (photocraft's merged images come from
    /// photocraft-compose), deterministic so composites compare exactly with `flatten`.
    static let compositor = RenderCompositor(PCRender.DocumentCompositor(rasterizer: PlaceholderRasterizer(), backend: .cpu, metal: nil))
    private static let flattenLock = NSLock()
    private static let flattener = PCRender.DocumentCompositor(rasterizer: PlaceholderRasterizer(), backend: .cpu, metal: nil)

    /// A CMYK converter through ColorSync for an ICC profile (relative colorimetric with black
    /// point compensation, as PCPlatform's and photocraft-cms' transforms), for the tests that
    /// check a document's own CMYK profile is used (`IOOptions.cmykConverter`).
    struct ColorSyncCMYK: CMYKConverter {
        let cmyk: CGColorSpace
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        init?(_ icc: [UInt8]) {
            guard let space = CGColorSpace(iccData: Data(icc) as CFData), space.model == .cmyk else { return nil }
            cmyk = space
        }
        static func convert(_ c: [CGFloat], _ src: CGColorSpace, _ dst: CGColorSpace) -> [Float]? {
            let options = [CGColor.conversionBlackPointCompensation: true] as CFDictionary
            guard let color = CGColor(colorSpace: src, components: c), let out = color.converted(to: dst, intent: .relativeColorimetric, options: options),
                  let comps = out.components else { return nil }
            return comps.dropLast().map { Float($0) }
        }
        func cmykToRGB(_ c: SIMD4<Float>) -> SIMD3<Float> {
            let v = Self.convert([CGFloat(c.x), CGFloat(c.y), CGFloat(c.z), CGFloat(c.w), 1], cmyk, srgb) ?? [0, 0, 0]
            return SIMD3(v[0], v[1], v[2])
        }
        func rgbToCMYK(_ rgb: SIMD3<Float>) -> SIMD4<Float> {
            let v = Self.convert([CGFloat(rgb.x), CGFloat(rgb.y), CGFloat(rgb.z), 1], srgb, cmyk) ?? [0, 0, 0, 1]
            return SIMD4(v[0], v[1], v[2], v[3])
        }
    }

    /// `options()` that reads and writes CMYK documents through their own ICC profile.
    static func cmykProfileOptions() -> IOOptions {
        var o = options()
        o.cmykConverter = { ColorSyncCMYK($0) }
        return o
    }

    /// photocraft's `ExportOptions::default()` / import: the CPU compositor (fill layers are
    /// rendered by PCIO itself, through PCRender's `FillLayerRenderer`).
    static func options(tiffLayers: Bool = false, forcePSB: Bool = false) -> IOOptions {
        IOOptions(compositor: compositor, forcePSB: forcePSB, tiffLayers: tiffLayers)
    }

    /// photocraft `photocraft_compose::flatten(doc).px`: the composite as straight sRGB RGBA.
    static func flatten(_ d: Document) throws -> [SIMD4<Float>] {
        try flattenLock.withLock { try flattener.flatten(d).px }
    }

    /// photocraft `photocraft_compose::render(doc, r).px`.
    static func flattenRegion(_ d: Document, _ r: PixelRect) throws -> [SIMD4<Float>] {
        try flattenLock.withLock { try flattener.render(d, region: r).px }
    }

    /// The largest difference of premultiplied colour and of alpha between two straight RGBA pixels.
    static func pixelError(_ a: SIMD4<Float>, _ b: SIMD4<Float>) -> Float {
        let d = a * a.w - b * b.w
        return max(abs(d.x), abs(d.y), abs(d.z), abs(a.w - b.w))
    }

    /// photocraft `common::max_diff`: the largest difference of premultiplied colour and alpha over
    /// pixels where either side is not fully transparent.
    static func maxDiff(_ a: [SIMD4<Float>], _ b: [SIMD4<Float>]) -> Float {
        var m: Float = 0
        for (p, q) in zip(a, b) {
            if p.w <= 0 && q.w <= 0 { continue }
            for c in 0 ..< 4 {
                let (x, y) = c < 3 ? (p[c] * p.w, q[c] * q.w) : (p[c], q[c])
                m = max(m, abs(x - y))
            }
        }
        return m
    }

    // MARK: - Import and export

    /// photocraft `photocraft_io::import`.
    static func importFile(_ name: String, _ bytes: [UInt8], options: IOOptions = options()) throws -> ImportResult {
        try DocumentIO.importFile(name: name, bytes: bytes, options: options)
    }

    /// photocraft `photocraft_io::export`; every PSD/PSB written also passes PCPSD's linter.
    static func export(_ d: Document, _ name: String, options: IOOptions = options(), sourceLocation: SourceLocation = #_sourceLocation) throws -> ExportResult {
        let r = try DocumentIO.export(d, as: name, options: options)
        let ext = DocumentIO.fileExtension(name.contains(".") ? name : "x.\(name)")
        if ext == "psd" || ext == "psb" {
            let errs = lintErrors(r.bytes)
            let mode32 = errs.filter { $0.contains("has no 32-bit") }
            #expect(errs.count == mode32.count, "\(name): linter errors \(errs.prefix(4))", sourceLocation: sourceLocation)
            withKnownIssue("PCIO (like photocraft) writes 32-bit CMYK/Lab PSDs, a mode Photoshop does not have", isIntermittent: true) {
                #expect(mode32.isEmpty, "\(name): \(mode32)", sourceLocation: sourceLocation)
            }
        }
        return r
    }

    /// Error-severity findings of PCPSD's Photoshop-compatibility linter.
    static func lintErrors(_ bytes: [UInt8]) -> [String] {
        guard let f = try? PSDFile(bytes: bytes) else { return ["unparseable"] }
        return f.compatibilityIssues(decodeChannels: true).filter { $0.severity == .error }.map(\.description)
    }

    /// The error `body` throws, if any.
    static func error<T>(_ body: () throws -> T) -> (any Error)? {
        do {
            _ = try body()
            return nil
        } catch {
            return error
        }
    }

    /// photocraft `codecs::decode`: the image turned upright by its orientation.
    static func decode(_ bytes: [UInt8]) throws -> DecodedImage { FlatOrientation.upright(try ImageIOCodec().decode(bytes)) }

    /// DocDiff problems (photocraft `assert_docs_eq`), for `#expect(... .isEmpty)`.
    static func diff(_ a: Document, _ b: Document) -> [String] { Array(DocDiff.of(a, b).prefix(8)) }

    /// `s` over `r` without its alpha channel.
    static func withoutAlpha(_ s: Surface, _ r: PixelRect) -> Surface {
        let fmt = s.format.with(alpha: false)
        let (ch, cc) = (s.format.channels, fmt.channels)
        let v = s.readRegion(r)
        var out = Surface(format: fmt)
        out.writeRegion(r, (0 ..< r.area).flatMap { i in v[i * ch ..< i * ch + cc] })
        return out
    }

    /// Runs `body` on a thread with an 8 MiB stack (a main thread's), waiting for it.
    static func onLargeStack<T: Sendable>(_ body: @escaping @Sendable () throws -> T) throws -> T {
        let box = ResultBox<T>()
        let done = DispatchSemaphore(value: 0)
        let t = Thread {
            box.result = Result { try body() }
            done.signal()
        }
        t.stackSize = 8 << 20
        t.start()
        done.wait()
        return try box.result!.get()
    }

    final class ResultBox<T>: @unchecked Sendable { var result: Result<T, any Error>? }

    // MARK: - Documents

    /// A 9×6 document with one raster "Background" (seed 3) in `mode`/`depth` (flat.rs `single`).
    static func single(_ mode: ColorMode, _ depth: SampleType, _ alpha: Bool) -> Document {
        var d = Document(name: "s", size: PixelSize(width: 9, height: 6), mode: mode, depth: depth)
        d.layers.append(rasterLayer("Background", d.pixelFormat, d.bounds, 3, alpha))
        return d
    }

    /// The largest sample difference between the first layers of `a` and `b` over `a`'s canvas;
    /// nil when the layers' sample counts differ (flat.rs `pixels_eq`).
    static func pixelDiff(_ a: Document, _ b: Document) -> Float? {
        guard let sa = a.layers.first?.surface, let sb = b.layers.first?.surface else { return nil }
        let (va, vb) = (sa.readRegion(a.bounds), sb.readRegion(a.bounds))
        guard va.count == vb.count else { return nil }
        return zip(va, vb).reduce(Float(0)) { max($0, abs($1.0 - $1.1)) }
    }

    /// An opaque 4×4 document filled with `#808080` (flat.rs `mid_gray`).
    static func midGray(_ mode: ColorMode, _ depth: SampleType) -> Document {
        var d = Document(name: "g", size: PixelSize(width: 4, height: 4), mode: mode, depth: depth)
        var s = Surface(format: d.pixelFormat)
        let v: Float = 128 / 255
        s.fill(d.bounds, with: d.pixelFormat.components(fromRGBA: SIMD4(v, v, v, 1)))
        d.layers.append(Layer(name: "Background", content: .raster(s)))
        return d
    }

    /// A 32×16 8-bit smooth ramp (flat.rs `smooth`).
    static func smooth(_ mode: ColorMode) -> Document {
        var d = Document(name: "s", size: PixelSize(width: 32, height: 16), mode: mode, depth: .u8)
        let fmt = d.pixelFormat
        var s = Surface(format: fmt)
        let n = fmt.channels
        var v: [Float] = []
        for y in 0 ..< 16 {
            for x in 0 ..< 32 {
                for c in 0 ..< n - 1 { v.append(min(Float(x * 4 + y * 2 + c * 20) / 255, 1)) }
                v.append(1)
            }
        }
        s.writeRegion(d.bounds, v)
        d.layers.append(Layer(name: "Background", content: .raster(s)))
        return d
    }

    /// A one-layer document of 16-pixel-wide columns, each one straight colour (flat.rs `columns`).
    static func columns(_ mode: ColorMode, _ depth: SampleType, _ cols: [[Float]]) -> Document {
        var d = Document(name: "c", size: PixelSize(width: 16 * cols.count, height: 16), mode: mode, depth: depth)
        var s = Surface(format: d.pixelFormat)
        for (i, px) in cols.enumerated() {
            let x = Int32(16 * i)
            s.fill(PixelRect(x0: x, y0: 0, x1: x + 16, y1: 16), with: px)
        }
        d.layers.append(Layer(name: "Layer", content: .raster(s)))
        return d
    }

    /// The pixel at the centre of each column (flat.rs `column_pixels`).
    static func columnPixels(_ d: Document, _ n: Int) -> [[Float]] {
        guard let s = d.layers.first?.surface else { return [] }
        return (0 ..< n).map { s.pixel(x: Int32(16 * $0 + 8), y: 8) }
    }

    /// Whether the leading (colour) channels of `got` are within `tol` of `want`.
    static func colorsMatch(_ got: [[Float]], _ want: [[Float]], _ tol: Float) -> Bool {
        got.count == want.count && zip(got, want).allSatisfy { g, w in zip(w, g).allSatisfy { abs($0 - $1) <= tol } }
    }

    // MARK: - ImageIO fixtures

    enum Model { case gray, rgb, cmyk }

    /// Encodes raw interleaved big-endian samples with ImageIO (straight alpha last).
    static func imageIO(_ samples: [UInt8], width: Int, height: Int, bpc: Int, model: Model = .rgb, alpha: Bool, float: Bool = false,
                        type: UTType = .png, space: CGColorSpace? = nil, properties: [CFString: Any] = [:]) -> [UInt8]? {
        let cc = model == .gray ? 1 : model == .rgb ? 3 : 4
        let comps = cc + (alpha ? 1 : 0)
        let cs = space ?? (model == .gray ? CGColorSpaceCreateDeviceGray() : model == .cmyk ? CGColorSpaceCreateDeviceCMYK() : CGColorSpace(name: CGColorSpace.sRGB)!)
        var info = alpha ? CGImageAlphaInfo.last.rawValue : CGImageAlphaInfo.none.rawValue
        if float { info |= CGBitmapInfo.floatComponents.rawValue | (bpc == 16 ? CGBitmapInfo.byteOrder16Big.rawValue : CGBitmapInfo.byteOrder32Big.rawValue) }
        else if bpc == 16 { info |= CGBitmapInfo.byteOrder16Big.rawValue }
        guard let provider = CGDataProvider(data: Data(samples) as CFData),
              let img = CGImage(width: width, height: height, bitsPerComponent: bpc, bitsPerPixel: bpc * comps, bytesPerRow: width * comps * bpc / 8,
                                space: cs, bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider, decode: nil, shouldInterpolate: false,
                                intent: .defaultIntent) else { return nil }
        let out = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(out as CFMutableData, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dst, img, properties as CFDictionary)
        guard CGImageDestinationFinalize(dst) else { return nil }
        return [UInt8](out as Data)
    }

    /// 16-bit samples as big-endian bytes.
    static func be16(_ v: [UInt16]) -> [UInt8] { v.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] } }

    // MARK: - PNG chunks

    static func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }

    /// A PNG chunk with its CRC.
    static func chunk(_ kind: String, _ data: [UInt8]) -> [UInt8] {
        let body = Array(kind.utf8) + data
        return be32(UInt32(data.count)) + body + be32(CRC32.checksum(body))
    }

    /// `png` with `chunks` inserted right after IHDR.
    static func inserting(_ png: [UInt8], _ chunks: [[UInt8]]) -> [UInt8] {
        let ihdrEnd = 8 + 8 + 13 + 4
        return Array(png[..<ihdrEnd]) + chunks.flatMap { $0 } + Array(png[ihdrEnd...])
    }

    /// `png` without its chunks of type `kind`.
    static func removingChunks(_ png: [UInt8], _ kind: String) -> [UInt8] {
        var out = Array(png.prefix(8))
        var at = 8
        while at + 12 <= png.count {
            let n = Int(png[at]) << 24 | Int(png[at + 1]) << 16 | Int(png[at + 2]) << 8 | Int(png[at + 3])
            let end = at + 12 + n
            guard end <= png.count else { break }
            if String(decoding: png[at + 4 ..< at + 8], as: UTF8.self) != kind { out += png[at ..< end] }
            at = end
        }
        return out
    }

    /// An 8-bit palette PNG (photocraft `encode_png_indexed`): `transparent` marks one entry with
    /// alpha 0 (a tRNS chunk).
    static func indexedPNG(_ w: Int, _ h: Int, _ indices: [UInt8], _ palette: [[UInt8]], transparent: UInt8?) throws -> [UInt8] {
        var out: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        out += chunk("IHDR", be32(UInt32(w)) + be32(UInt32(h)) + [8, 3, 0, 0, 0])
        out += chunk("PLTE", palette.flatMap { $0 })
        if let t = transparent { out += chunk("tRNS", (0 ... Int(t)).map { $0 == Int(t) ? 0 : 255 }) }
        var raw: [UInt8] = []
        for y in 0 ..< h { raw.append(0); raw += indices[y * w ..< (y + 1) * w] }
        out += chunk("IDAT", try Deflate.zlibDeflate(raw))
        out += chunk("IEND", [])
        return out
    }

    // MARK: - ICC profiles

    /// The ICC profile of a named CoreGraphics colour space.
    static func icc(_ name: CFString) -> [UInt8]? { CGColorSpace(name: name)?.copyICCData().map { [UInt8]($0 as Data) } }

    /// The profile's colour space signature (header bytes 16–19: `RGB `, `GRAY`, `CMYK`, `Lab `).
    static func iccSpace(_ icc: [UInt8]) -> String { icc.count >= 20 ? String(decoding: icc[16 ..< 20], as: UTF8.self) : "" }

    /// The profile's description (`desc` tag: `desc` or `mluc` type), photocraft `Profile::description`.
    static func iccDescription(_ p: [UInt8]) -> String? {
        func u32(_ at: Int) -> Int? { at >= 0 && at + 4 <= p.count ? Int(p[at]) << 24 | Int(p[at + 1]) << 16 | Int(p[at + 2]) << 8 | Int(p[at + 3]) : nil }
        guard let n = u32(128) else { return nil }
        for i in 0 ..< min(n, 256) {
            let e = 132 + i * 12
            guard e + 12 <= p.count, Array(p[e ..< e + 4]) == Array("desc".utf8), let off = u32(e + 4), off + 12 <= p.count else { continue }
            let type = String(decoding: p[off ..< off + 4], as: UTF8.self)
            if type == "desc", let len = u32(off + 8), off + 12 + len <= p.count {
                return String(decoding: p[off + 12 ..< off + 12 + len].prefix { $0 != 0 }, as: UTF8.self)
            }
            if type == "mluc", let count = u32(off + 8), count > 0, let len = u32(off + 20), let at = u32(off + 24), off + at + len <= p.count {
                let units = stride(from: off + at, to: off + at + len - 1, by: 2).map { UInt16(p[$0]) << 8 | UInt16(p[$0 + 1]) }
                return String(decoding: units, as: UTF16.self)
            }
        }
        return nil
    }

    // MARK: - EXIF and JPEG

    /// An EXIF block with only an Orientation tag (orientation.rs `exif`).
    static func exif(orientation o: UInt16) -> [UInt8] {
        [0x49, 0x49, 0x2A, 0, 8, 0, 0, 0, 1, 0, 0x12, 0x01, 3, 0, 1, 0, 0, 0] + [UInt8(o & 0xFF), UInt8(o >> 8)] + [0, 0, 0, 0, 0, 0]
    }

    /// `jpeg` with an APP1 `Exif` segment holding `exif` right after SOI.
    static func jpegWithExif(_ jpeg: [UInt8], _ exif: [UInt8]) -> [UInt8] {
        let seg = Array("Exif\0\0".utf8) + exif
        let n = seg.count + 2
        return Array(jpeg[..<2]) + [0xFF, 0xE1, UInt8(n >> 8), UInt8(n & 0xFF)] + seg + Array(jpeg[2...])
    }

    /// photocraft-codecs `exif_orientation`: the Orientation (1–8) of an EXIF block or a TIFF
    /// file's first directory; 1 when absent, out of range or unreadable.
    static func exifOrientation(_ bytes: [UInt8]) -> Int {
        let b = bytes.starts(with: Array("Exif\0\0".utf8)) ? Array(bytes.dropFirst(6)) : bytes
        guard let entries = ifd0(b) else { return 1 }
        for e in entries where e.tag == 274 && e.count == 1 && (e.type == 3 || e.type == 4) {
            let v = Int(e.value)
            return (1 ... 8).contains(v) ? v : 1
        }
        return 1
    }

    /// One IFD0 entry: tag, type, count, and the inline value (first SHORT/LONG, or the offset).
    struct Entry { var tag: Int; var type: Int; var count: UInt64; var value: UInt64; var at: Int }

    /// The entries of IFD0 of a TIFF structure (classic or BigTIFF, either byte order).
    static func ifd0(_ b: [UInt8]) -> [Entry]? {
        guard b.count >= 8 else { return nil }
        let little: Bool
        switch (b[0], b[1]) {
        case (0x49, 0x49): little = true
        case (0x4D, 0x4D): little = false
        default: return nil
        }
        func uint(_ at: Int, _ n: Int) -> UInt64? {
            guard at >= 0, at + n <= b.count else { return nil }
            var v: UInt64 = 0
            for i in 0 ..< n { v |= UInt64(b[at + (little ? i : n - 1 - i)]) << (8 * UInt64(i)) }
            return v
        }
        guard let magic = uint(2, 2), magic == 42 || magic == 43 else { return nil }
        let big = magic == 43
        let off = big ? 8 : 4
        guard let first = uint(big ? 8 : 4, off), first < UInt64(b.count) else { return nil }
        let at = Int(first)
        guard let count = uint(at, big ? 8 : 2) else { return nil }
        let start = at + (big ? 8 : 2)
        let size = big ? 20 : 12
        var out: [Entry] = []
        for i in 0 ..< Int(min(count, 4096)) {
            let e = start + i * size
            guard let tag = uint(e, 2), let type = uint(e + 2, 2), let n = uint(e + 4, off) else { break }
            let valueAt = e + 4 + off
            let width = type == 3 ? 2 : (type == 16 ? 8 : 4)
            let value = uint(valueAt, min(width, off)) ?? 0
            out.append(Entry(tag: Int(tag), type: Int(type), count: n, value: value, at: valueAt))
        }
        return out
    }

    // MARK: - TIFF

    /// The two Photoshop tags of a TIFF: (resources, layers) (tiff_layers.rs `tags`).
    static func tags(_ bytes: [UInt8]) -> (resources: [UInt8]?, layers: [UInt8]?) {
        let t = LayeredTIFF.photoshopTags(bytes)
        return (t?.resources, t?.layers)
    }

    /// The raw bytes of a BYTE/ASCII/UNDEFINED tag of a classic TIFF's first directory.
    static func rawTag(_ tiff: [UInt8], _ tag: Int) -> [UInt8]? {
        guard let e = ifd0(tiff)?.first(where: { $0.tag == tag && [1, 2, 7].contains($0.type) }), e.count <= UInt64(tiff.count) else { return nil }
        let n = Int(e.count)
        let at = n <= 4 ? e.at : Int(e.value)
        guard at >= 0, at + n <= tiff.count else { return nil }
        return Array(tiff[at ..< at + n])
    }

    /// photocraft's `codecs::decode(tiff)` → change `meta` → `codecs::encode(Format::Tiff)`: the
    /// TIFF's composite (ImageIO), profile, XMP and Photoshop tags written again by
    /// `LayeredTIFF.write`, with `layers` (the 37724 data; nil keeps the file's), `dpi` (nil keeps
    /// the file's) and `compression` replaced.
    static func rewriteTIFF(_ tiff: [UInt8], layers: [UInt8]? = nil, dpi: (x: Double, y: Double)? = nil,
                            compression: LayeredTIFF.Compression = .deflate) throws -> [UInt8] {
        let img = try ImageIOCodec().decode(tiff)
        let tags = LayeredTIFF.photoshopTags(tiff)
        let fmt = img.surface.format
        var samples = img.surface.readInterleaved(PixelRect(x0: 0, y0: 0, x1: Int32(img.width), y1: Int32(img.height)))
        if !img.hasAlpha {
            let bps = fmt.sample.bytes, src = fmt.channels * bps, dst = fmt.mode.colorChannels * bps
            samples = (0 ..< img.width * img.height).flatMap { samples[$0 * src ..< $0 * src + dst] }
        }
        let image = LayeredTIFF.Image(width: img.width, height: img.height, mode: fmt.mode, alpha: img.hasAlpha, sample: fmt.sample, samples: samples,
                                      iccProfile: rawTag(tiff, Int(LayeredTIFF.iccTag)), xmp: tags?.xmp, dpi: dpi ?? img.dpi,
                                      photoshopResources: tags?.resources, photoshopLayers: layers ?? tags?.layers)
        return try LayeredTIFF.write(image, options: LayeredTIFF.WriteOptions(compression: compression))
    }

    // MARK: - Containers

    /// A ZIP archive with a stored `mimetype` first, then the named entries.
    static func archive(_ mime: [UInt8], _ entries: [(String, [UInt8])]) -> [UInt8] {
        var z = ZipWriter()
        try? z.add("mimetype", mime)
        for (n, d) in entries { try? z.add(n, d) }
        return (try? z.finish()) ?? []
    }

    /// A PNG through ImageIO of `w`×`h` copies of one RGBA8 pixel.
    static func solidPNG(_ w: Int, _ h: Int, _ rgba: [UInt8]) -> [UInt8] {
        let rect = PixelRect(x0: 0, y0: 0, x1: Int32(w), y1: Int32(h))
        let s = Surface(format: .rgba8, rect: rect, interleaved: Array([[UInt8]](repeating: rgba, count: w * h).joined()))
        return (try? ImageIOCodec().encode(s, rect: rect, as: .png, quality: nil, iccProfile: nil)) ?? []
    }

    /// A 16-bit gray PNG of a ramp (value i·1000 at pixel i).
    static func gray16PNG(_ w: Int, _ h: Int) -> [UInt8] {
        let rect = PixelRect(x0: 0, y0: 0, x1: Int32(w), y1: Int32(h))
        var bytes: [UInt8] = []
        for i in 0 ..< w * h { let v = UInt16(truncatingIfNeeded: i * 1000); bytes += [UInt8(v & 0xFF), UInt8(v >> 8)] }
        let s = Surface(format: .gray16, rect: rect, interleaved: bytes)
        return (try? ImageIOCodec().encode(s, rect: rect, as: .png, quality: nil, iccProfile: nil)) ?? []
    }

    /// A raster layer holding a `w`×`h` block at (`x`, `y`) of a colour ramp (ora tests `block`).
    static func block(_ name: String, _ fmt: PixelFormat, _ x: Int32, _ y: Int32, _ w: Int, _ h: Int, _ seed: Int) -> Layer {
        var data: [UInt8] = []
        for j in 0 ..< h {
            for i in 0 ..< w {
                func v(_ k: Int) -> Float { Float((i * 7 + j * 13 + k * 29 + seed * 31) % 256) / 255 }
                let rgba: [Float] = [v(0), v(1), v(2), 0.25 + 0.75 * v(3)]
                data += encodePixel(fmt, fmt.mode == .grayscale ? [rgba[0], rgba[3]] : rgba)
            }
        }
        return Layer(name: name, content: .raster(Surface(format: fmt, rect: PixelRect(x: Int(x), y: Int(y), width: w, height: h), interleaved: data)))
    }

    /// The OpenRaster test document (ora tests `doc`).
    static func oraDoc(_ depth: SampleType) -> Document {
        let fmt = PixelFormat(mode: .rgb, sample: depth, alpha: true)
        var d = Document(name: "t.ora", size: PixelSize(width: 70, height: 50), mode: .rgb, depth: depth)
        var base = block("Base", fmt, 0, 0, 70, 50, 1)
        base.locks.transparency = true
        var off = block("Off canvas", fmt, -12, 30, 40, 30, 2)
        off.blend = .multiply
        off.opacity = 0.5
        var hidden = block("Hidden", fmt, 10, 10, 5, 5, 3)
        hidden.visible = false
        var inner = block("Inner screen", fmt, 20, 5, 30, 20, 4)
        inner.blend = .screen
        var group = Layer.group("Isolated", [inner, block("Inner plain", fmt, 5, 5, 8, 8, 5)])
        group.blend = .overlay
        group.opacity = 0.75
        var throughChild = block("Through child", fmt, 40, 20, 25, 25, 6)
        throughChild.blend = .linearLight
        throughChild.locks.all = true
        let through = Layer.group("Pass <&> \"through\"", [throughChild])
        d.layers = [base, off, hidden, group, through]
        return d
    }

    /// The synthetic Paint.NET writer of photocraft's pdn tests (`fixture`): `modes` one layer each,
    /// 2×2, legacy or `blendMode` properties, raw or gzip pixel chunks.
    static func pdn(_ modes: [Int32], legacy: Bool, compressed: Bool) -> [UInt8] {
        enum Field { case int(Int32), long(Int64), byte(UInt8), bool(Bool), ref(Int32) }
        struct Writer {
            var b: [UInt8]
            mutating func int(_ n: Int32) {
                let u = UInt32(bitPattern: n)
                b += [UInt8(u & 0xFF), UInt8(u >> 8 & 0xFF), UInt8(u >> 16 & 0xFF), UInt8(u >> 24)]
            }
            mutating func string(_ s: String) {
                var len = s.utf8.count
                while len >= 128 { b.append(UInt8(len & 127) | 128); len >>= 7 }
                b.append(UInt8(len))
                b += Array(s.utf8)
            }
            mutating func object(_ id: Int32, _ cls: String, _ fields: [(String, Field)]) {
                b.append(5)
                int(id)
                string(cls)
                int(Int32(fields.count))
                for (name, _) in fields { string(name) }
                for (_, f) in fields { if case .ref = f { b.append(2) } else { b.append(0) } }
                for (_, f) in fields {
                    switch f {
                    case .int: b.append(8)
                    case .long: b.append(9)
                    case .byte: b.append(2)
                    case .bool: b.append(1)
                    case .ref: break
                    }
                }
                int(1)
                for (_, f) in fields {
                    switch f {
                    case let .int(n): int(n)
                    case let .long(n): for k in 0 ..< 8 { b.append(UInt8(truncatingIfNeeded: n >> (8 * k))) }
                    case let .byte(n): b.append(n)
                    case let .bool(v): b.append(v ? 1 : 0)
                    case let .ref(id): b.append(9); int(id)
                    }
                }
            }
        }
        var w = Writer(b: Array("PDN3".utf8) + [0, 0, 0, 0, 1])
        w.b.append(0)
        for n: Int32 in [1, -1, 1, 0] { w.int(n) }
        w.b.append(12)
        w.int(1)
        w.string("PaintDotNet.Data")
        w.object(1, "PaintDotNet.Document", [("width", .int(2)), ("height", .int(2)), ("layers", .ref(2))])
        w.object(2, "PaintDotNet.LayerList", [("parent", .ref(1)), ("ArrayList+_size", .int(Int32(modes.count))), ("ArrayList+_items", .ref(3))])
        w.b.append(16)
        w.int(3)
        w.int(Int32(modes.count) + 2)
        for i in modes.indices { w.b.append(9); w.int(16 + Int32(i) * 10) }
        w.b += [13, 2]
        for (i, mode) in modes.enumerated() {
            let id = 16 + Int32(i) * 10
            w.object(id, "PaintDotNet.BitmapLayer", [("Layer+width", .int(2)), ("Layer+height", .int(2)), ("surface", .ref(id + 1)),
                                                     ("Layer+properties", .ref(id + 2)), ("properties", .ref(id + 3))])
            w.object(id + 1, "PaintDotNet.Surface", [("width", .int(2)), ("height", .int(2)), ("stride", .int(12)), ("scan0", .ref(id + 7))])
            var fields: [(String, Field)] = [("name", .ref(id + 4)), ("opacity", .byte(i == 0 ? 255 : 128)), ("visible", .bool(i != 1)),
                                             ("isBackground", .bool(i == 0))]
            if !legacy { fields.append(("blendMode", .ref(id + 5))) }
            w.object(id + 2, "PaintDotNet.Layer+LayerProperties", fields)
            w.object(id + 3, "PaintDotNet.BitmapLayer+BitmapLayerProperties", [("blendOp", .ref(id + 6))])
            w.b.append(6)
            w.int(id + 4)
            w.string("Läyer \(i)")
            w.object(id + 5, "PaintDotNet.LayerBlendMode", [("value__", .int(mode))])
            let old = mode >= 0 && Int(mode) < PaintDotNet.oldModes.count ? PaintDotNet.oldModes[Int(mode)] : "Unknown"
            w.object(id + 6, "PaintDotNet.UserBlendOps+\(old)BlendOp", [])
            w.object(id + 7, "PaintDotNet.MemoryBlock", [("length64", .long(24)), ("hasParent", .bool(false)), ("deferred", .bool(true))])
        }
        w.b.append(11)
        for _ in modes {
            w.b.append(compressed ? 0 : 1)
            w.b += [0, 0, 0, 12]
            for index: UInt32 in [1, 0] {
                let raw: [UInt8] = index == 0 ? [30, 20, 10, 255, 60, 50, 40, 128, 99, 99, 99, 99] : [90, 80, 70, 64, 120, 110, 100, 0, 99, 99, 99, 99]
                let data = compressed ? ((try? Deflate.gzip(raw)) ?? []) : raw
                w.b += be32(index) + be32(UInt32(data.count)) + data
            }
        }
        return w.b
    }
}
