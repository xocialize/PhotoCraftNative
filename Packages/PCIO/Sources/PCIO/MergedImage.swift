// The merged composite of a PSD export, rendered by the injected compositor in bands and encoded
// as PSD planes; the thumbnail resource (1036); the merged composite of a PSD as straight floats
// (the compositing oracle's reference).
// Port of photocraft-io (crates/io/src/psd_export.rs: merged_planes; psd_thumbnail.rs;
// lib.rs: merged_composite), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import CoreGraphics
import Foundation
import PCDocument
import PCFoundation
import PCIOCore
import PCPSD
import PCRender

public enum MergedImage {
    public struct Planes: Sendable {
        /// Colour planes then alpha, big-endian, each `width × height` samples.
        public var planes: [UInt8]
        /// Whether any pixel needs the alpha channel at the stored precision.
        public var hasAlpha: Bool
        /// Whether any pixel has alpha below 1.
        public var translucent: Bool
        /// Whether the compositor succeeded (a failed band is left white).
        public var status: Result<Void, PCIOError>
    }

    /// The merged image's planes (colour channels, then alpha), big-endian, matted against white
    /// when `matte` (photocraft `merged_planes`, plus the re-encode without the matte when some
    /// pixels are translucent but all round to opaque). Rendered a band of tile rows at a time.
    public static func planes(_ doc: Document, fmt: PixelFormat, compositor: any PCIOCore.DocumentCompositor, matte: Bool, interrupt: Interrupt) -> Planes {
        var p = render(doc, fmt: fmt, compositor: compositor, matte: matte, interrupt: interrupt)
        if !p.hasAlpha && p.translucent && matte {
            p = render(doc, fmt: fmt, compositor: compositor, matte: false, interrupt: .cancelOnly { interrupt.isCancelled })
            p.hasAlpha = false
        }
        return p
    }

    static func render(_ doc: Document, fmt: PixelFormat, compositor: any PCIOCore.DocumentCompositor, matte: Bool, interrupt: Interrupt) -> Planes {
        let sample = fmt.sample
        let cc = fmt.mode.colorChannels
        let ch = cc + 1
        let bps = sample.bytes
        let w = doc.size.width, h = doc.size.height
        let n = w * h
        let plane = n * bps
        var planes = [UInt8](repeating: 0, count: plane * ch)
        var hasAlpha = false, translucent = false
        var status: Result<Void, PCIOError> = .success(())
        let white = fmt.components(fromRGBA: SIMD4(1, 1, 1, 1))
        let lab16 = fmt.mode == .lab && sample == .u16
        let cmyk = fmt.mode == .cmyk
        let canvas = doc.bounds
        var y = canvas.y0
        while y < canvas.y1 {
            if interrupt.isCancelled { break }
            let band = PixelRect(x0: canvas.x0, y0: y, x1: canvas.x1, y1: min(y &+ tileSize, canvas.y1))
            var vals: [Float]
            do {
                vals = try compositor.composite(doc, rect: band)
                if vals.count != band.area * ch { throw PCIOError.codec("compositor returned \(vals.count) samples for \(band.area * ch)") }
            } catch {
                status = .failure(PCIOError.wrap(error))
                vals = [Float](repeating: 0, count: band.area * ch)
                for i in 0 ..< band.area {
                    for c in 0 ..< cc { vals[i * ch + c] = white[c] }
                    vals[i * ch + cc] = 1
                }
            }
            let start = Int(band.y0 - canvas.y0) * w
            vals.withUnsafeBufferPointer { v in
                planes.withUnsafeMutableBytes { out in
                    for i in 0 ..< band.area {
                        let a = v[i * ch + cc]
                        switch sample {
                        case .u8: if PSDExport.q255(a) < 255 { hasAlpha = true }
                        case .u16: if (a.isNaN ? 0 : UInt16(min(max(a, 0), 1) * 65535 + 0.5)) != UInt16.max { hasAlpha = true }
                        case .f32: if a != 1 { hasAlpha = true }
                        }
                        if a < 1 { translucent = true }
                        for c in 0 ... cc {
                            // Matte against white like Photoshop.
                            let m = c < cc && matte ? PSDPixels.matte(v[i * ch + c], a, white[c]) : v[i * ch + c]
                            var x = cmyk && c < cc ? 1 - m : m
                            // 16-bit Lab a*/b* use Photoshop's 0...65280 scale.
                            if lab16 && (c == 1 || c == 2) { x *= PSDPixels.lab16ChromaMax / 65535 }
                            let o = c * plane + (start + i) * bps
                            switch sample {
                            case .u8: out[o] = x.isNaN ? 0 : UInt8(min(max(x, 0), 1) * 255 + 0.5)
                            case .u16:
                                let q = x.isNaN ? 0 : UInt16(min(max(x, 0), 1) * 65535 + 0.5)
                                out[o] = UInt8(q >> 8); out[o + 1] = UInt8(q & 0xFF)
                            case .f32:
                                let b = x.bitPattern
                                out[o] = UInt8(b >> 24); out[o + 1] = UInt8(b >> 16 & 0xFF); out[o + 2] = UInt8(b >> 8 & 0xFF); out[o + 3] = UInt8(b & 0xFF)
                            }
                        }
                    }
                }
            }
            interrupt.progress(Float(band.y1 - canvas.y0) / Float(max(1, h)))
            y = band.y1
        }
        return Planes(planes: planes, hasAlpha: hasAlpha, translucent: translucent, status: status)
    }

    /// The PSD's merged composite as straight RGBA floats (row-major): converted with the
    /// document pixel model and un-matted from white (Photoshop mattes the merged image of
    /// transparent documents). The compositing oracle's reference (photocraft `merged_composite`).
    public static func composite(_ file: PSDFile) throws -> [SIMD4<Float>] {
        let h = file.header
        do { try h.validate() } catch { throw PCIOError.wrap(error) }
        let w = Int(h.width), hh = Int(h.height)
        if h.colorMode == .rgb, file.mergedHasAlpha {
            // Native sample precision before removing the white matte.
            let raw: [UInt8]
            do { raw = try file.decodeMerged() } catch { throw PCIOError.wrap(error) }
            let plane = raw.count / Int(max(h.channels, 1))
            if plane == 0 { throw PCIOError.psd("empty RGB composite") }
            var planes: [[Float]] = []
            for c in 0 ..< 4 {
                guard (c + 1) * plane <= raw.count else { throw PCIOError.psd("missing RGB composite channels") }
                let bytes = Array(raw[c * plane ..< (c + 1) * plane])
                switch h.depth {
                case 32: planes.append(PSDSamples.f32(bytes))
                case 16: planes.append(PSDSamples.u16(bytes).map { Float($0) / 65535 })
                default:
                    do { planes.append(try PSDSamples.planeToU8(bytes, depth: h.depth, width: w, height: hh).map { Float($0) / 255 }) } catch { throw PCIOError.wrap(error) }
                }
            }
            let n = min(planes[0].count, planes[1].count, planes[2].count, planes[3].count)
            return (0 ..< n).map { i in
                var p = SIMD4(planes[0][i], planes[1][i], planes[2][i], planes[3][i])
                for c in 0 ..< 3 {
                    p[c] = PSDPixels.unmatte(p[c], p.w, 1)
                    if h.depth != 32 { p[c] = min(max(p[c], 0), 1) }
                }
                return p
            }
        }
        // The RGBA8 preview clips signed/HDR values: decode float merged images through the
        // model path below. CMYK and Lab go through the model conversion too.
        if h.depth != 32, h.colorMode != .lab, h.colorMode != .cmyk, let img = try? file.compositeRGBA8(unmatte: false) {
            let unmatte = file.mergedHasAlpha
            return (0 ..< img.width * img.height).map { i in
                var v = SIMD4(Float(img.data[i * 4]) / 255, Float(img.data[i * 4 + 1]) / 255, Float(img.data[i * 4 + 2]) / 255, Float(img.data[i * 4 + 3]) / 255)
                if unmatte { for c in 0 ..< 3 { v[c] = min(max(PSDPixels.unmatte(v[c], v.w, 1), 0), 1) } }
                return v
            }
        }
        // Generic path (Lab, CMYK and others) via the document model. Keep the merged-alpha
        // marker while discarding layers: otherwise an extra channel is mistaken for transparency.
        var flat = file
        flat.layerInfo = PSDLayerInfo(mergedAlpha: file.mergedHasAlpha, layers: [], padding: nil)
        let (doc, _) = try PSDImport.document(flat)
        // Multichannel documents keep their channels apart (no layer): composite them.
        if doc.layers.isEmpty, doc.mode == .multichannel {
            do { return try RenderCompositor.shared.compositor.render(doc, region: doc.bounds).px } catch {
                throw PCIOError.codec("composite failed: \(error)")
            }
        }
        guard let s = doc.layers.first?.surface else { throw PCIOError.unsupported("no merged image") }
        return s.readRGBA(doc.bounds)
    }
}

/// The PSD/PSB thumbnail image resource (1036), written when Preferences › File Handling › Image
/// Previews saves them (Photoshop's default). Layout (Adobe spec, "Thumbnail resource format"): a
/// 28-byte big-endian header (format 1 = kJpegRGB, width, height, widthbytes = (width × 24 + 31)
/// / 32 × 4, total size, compressed size, bits per pixel 24, planes 1) then the JFIF stream.
/// Photoshop keeps the long side at 160 px or less.
/// Port of photocraft-io (crates/io/src/psd_thumbnail.rs).
public enum PSDThumbnail {
    public static let maxSide = 160
    public static let headerLength = 28

    /// The 1036 resource: the composite reduced to at most `maxSide`, converted to sRGB through
    /// the document's profile, matted over white and JPEG-compressed.
    public static func resource(_ doc: Document, compositor: any PCIOCore.DocumentCompositor, codec: any FlatImageCodec) throws -> PSDImageResource {
        let (rgba, w, h) = try thumbnailRGBA(doc, compositor: compositor)
        guard w > 0, h > 0, w <= maxSide, h <= maxSide else { throw PCIOError.unsupported("the image preview could not be rendered") }
        var s = Surface(format: PixelFormat(mode: .rgb, sample: .u8, alpha: false))
        var vals = [Float](repeating: 0, count: w * h * 3)
        for i in 0 ..< w * h {
            let a = finite(rgba[i].w)
            for c in 0 ..< 3 { vals[i * 3 + c] = finite(rgba[i][c]) * a + (1 - a) }
        }
        let rect = PixelRect(x0: 0, y0: 0, x1: Int32(w), y1: Int32(h))
        s.writeRegion(rect, vals)
        let jfif = try codec.encode(s, rect: rect, as: .jpeg, quality: 0.8, iccProfile: nil)
        return PSDImageResource(id: PSDResourceID.thumbnail, data: Data(try thumbnailBytes(w, h, jfif)))
    }

    /// A sample clamped to 0...1 (NaN as 0).
    static func finite(_ v: Float) -> Float { v.isNaN ? 0 : min(max(v, 0), 1) }

    /// Header plus JFIF data of a `w`×`h` thumbnail resource.
    public static func thumbnailBytes(_ w: Int, _ h: Int, _ jfif: [UInt8]) throws -> [UInt8] {
        guard w >= 0, h >= 0, w <= 1 << 20, h <= 1 << 20, jfif.count <= Int(UInt32.max) else { throw PCIOError.unsupported("image preview too large") }
        let widthBytes = (w * 24 + 31) / 32 * 4
        var b = BEWriter()
        for v in [1, w, h, widthBytes, widthBytes * h, jfif.count] { b.u32(UInt32(v)) }
        b.u16(24)
        b.u16(1)
        b.put(jfif)
        return b.bytes
    }

    /// The composite reduced to fit `maxSide`, as straight sRGB RGBA (box filter, a band at a time).
    static func thumbnailRGBA(_ doc: Document, compositor: any PCIOCore.DocumentCompositor, side: Int = maxSide) throws -> ([SIMD4<Float>], Int, Int) {
        let W = doc.size.width, H = doc.size.height
        guard W > 0, H > 0 else { return ([], 0, 0) }
        let scale = min(1, Double(side) / Double(max(W, H)))
        let tw = max(1, Int((Double(W) * scale).rounded())), th = max(1, Int((Double(H) * scale).rounded()))
        var acc = [SIMD4<Float>](repeating: .zero, count: tw * th)
        var cnt = [Float](repeating: 0, count: tw * th)
        let fmt = doc.pixelFormat
        var y: Int32 = 0
        while y < Int32(H) {
            let band = PixelRect(x0: 0, y0: y, x1: Int32(W), y1: min(y &+ tileSize, Int32(H)))
            let vals = try compositor.composite(doc, rect: band)
            var s = Surface(format: fmt)
            s.writeRegion(band, vals)
            let rgba = s.readRGBA(band)
            for j in 0 ..< band.height {
                let ty = min(th - 1, (Int(band.y0) + j) * th / H)
                for i in 0 ..< W {
                    let tx = min(tw - 1, i * tw / W)
                    let p = rgba[j * W + i]
                    // Premultiplied average, so transparent pixels don't darken the edges.
                    acc[ty * tw + tx] += SIMD4(p.x * p.w, p.y * p.w, p.z * p.w, p.w)
                    cnt[ty * tw + tx] += 1
                }
            }
            y = band.y1
        }
        var out = [SIMD4<Float>](repeating: .zero, count: tw * th)
        for k in 0 ..< out.count where cnt[k] > 0 {
            let a = acc[k].w / cnt[k]
            out[k] = a > 0 ? SIMD4(acc[k].x / acc[k].w, acc[k].y / acc[k].w, acc[k].z / acc[k].w, a) : .zero
        }
        // Into sRGB through the document's own RGB/gray profile.
        if let icc = doc.iccProfile, fmt.mode == .rgb || fmt.mode == .grayscale, let space = CGColorSpace(iccData: Data(icc) as CFData),
           space.model == (fmt.mode == .rgb ? .rgb : .monochrome), let srgb = CGColorSpace(name: CGColorSpace.sRGB) {
            out = convert(out, tw, th, from: space, gray: fmt.mode == .grayscale, to: srgb)
        }
        return (out, tw, th)
    }

    static func convert(_ px: [SIMD4<Float>], _ w: Int, _ h: Int, from: CGColorSpace, gray: Bool, to: CGColorSpace) -> [SIMD4<Float>] {
        let comps = gray ? 1 : 3
        var src = [Float](repeating: 0, count: w * h * comps)
        for i in 0 ..< w * h { for c in 0 ..< comps { src[i * comps + c] = px[i][c] } }
        var dst = [Float](repeating: 0, count: w * h * 4)
        let ok = src.withUnsafeMutableBytes { s -> Bool in
            dst.withUnsafeMutableBytes { d -> Bool in
                let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
                guard let provider = CGDataProvider(data: Data(bytes: s.baseAddress!, count: s.count) as CFData),
                      let img = CGImage(width: w, height: h, bitsPerComponent: 32, bitsPerPixel: 32 * comps, bytesPerRow: w * comps * 4, space: from,
                                        bitmapInfo: info, provider: provider, decode: nil, shouldInterpolate: false, intent: .relativeColorimetric),
                      let ctx = CGContext(data: d.baseAddress, width: w, height: h, bitsPerComponent: 32, bytesPerRow: w * 16, space: to,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
                else { return false }
                ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
                return true
            }
        }
        guard ok else { return px }
        return (0 ..< w * h).map { SIMD4(dst[$0 * 4], dst[$0 * 4 + 1], dst[$0 * 4 + 2], px[$0].w) }
    }
}
