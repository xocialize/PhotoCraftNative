// Placing a `.comp` layer's pixels and masks on the document. Compositor keeps every layer as its
// own pixel grid plus a non-destructive transform (box, clockwise rotation, flips, sampling) and
// draws it with CoreGraphics; PCDocument layers are pixels in document space. A layer whose grid
// lands one-to-one on whole document pixels is copied exactly; any other is drawn the way
// Compositor's `LayerRenderer.draw` draws it (same placement, interpolation and antialiasing), into
// a float context so nothing is lost to 8-bit premultiplication: a smart object's rendered
// appearance, or a pixel layer's pixels (`CompImport.TransformedLayers`).
// Written from Compositor's Rendering/LayerRenderer.swift, Document/LayerMask.swift and
// Document/BrushStroke.swift (`pixelToDocument`); Compositor is MIT, © 2026 Wonder Assembly LLC.

import CoreGraphics
import Foundation
import PCDocument
import PCFoundation

enum CompPixels {
    /// What a placement did to the pixels.
    struct Placed {
        var surface: Surface
        /// The pixels were resampled (scale, rotation, flip or a fractional offset).
        var resampled: Bool
        /// Pixels beyond `limit` were left out.
        var cropped: Bool
    }

    /// The document area a transformed `w` × `h` grid covers, whole pixels outward.
    static func bounds(_ t: CompTransform, _ w: Int, _ h: Int) -> PixelRect {
        let m = t.pixelToDocument(w, h)
        let xs = [0.0, Double(w)], ys = [0.0, Double(h)]
        var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
        for x in xs { for y in ys {
            let px = m.a * x + m.c * y + m.tx, py = m.b * x + m.d * y + m.ty
            minX = min(minX, px); maxX = max(maxX, px); minY = min(minY, py); maxY = max(maxY, py)
        } }
        func clampI(_ v: Double) -> Int32 { Int32(max(-2_000_000, min(2_000_000, v))) }
        return PixelRect(x0: clampI(minX.rounded(.down)), y0: clampI(minY.rounded(.down)), x1: clampI(maxX.rounded(.up)), y1: clampI(maxY.rounded(.up)))
    }

    /// The transform a smart object holding the `w` × `h` grid is placed by: source pixels →
    /// document pixels, as `pixelToDocument`, with quarter turns exact (cos 90° is 0, not 6e-17),
    /// so a turn or flip back to 100 % lands on whole pixels.
    static func affine(_ t: CompTransform, _ w: Int, _ h: Int) -> PCAffine {
        var m = t.pixelToDocument(w, h)
        if t.rotation.truncatingRemainder(dividingBy: 90) == 0 {
            let scale = max(abs(m.a), abs(m.b), abs(m.c), abs(m.d))
            func snap(_ v: Double) -> Double { abs(v) < scale * 1e-9 ? 0 : v }
            (m.a, m.b, m.c, m.d) = (snap(m.a), snap(m.b), snap(m.c), snap(m.d))
            let cx = t.originX + t.width / 2, cy = t.originY + t.height / 2
            let hx = Double(w) / 2, hy = Double(h) / 2
            (m.tx, m.ty) = (cx - m.a * hx - m.c * hy, cy - m.b * hx - m.d * hy)
        }
        return PCAffine(a: m.a, b: m.b, c: m.c, d: m.d, e: m.tx, f: m.ty)
    }

    /// `LayerRenderer.interpolation` at export scale (one device pixel per document pixel; the
    /// halvings Compositor draws large reductions from are not reproduced).
    static func interpolation(_ t: CompTransform, _ w: Int) -> CGInterpolationQuality {
        let factor = t.width / Double(max(1, w))
        if t.sampling == .nearest || (t.radians == 0 && abs(factor - 1) < 0.001) { return .none }
        if factor <= 1 { return .low }
        return t.sampling == .high ? .high : .low
    }

    /// The layer's `src` grid (`w` × `h`, straight alpha, any RGB format) on the document, in
    /// `format`. Resampled pixels are kept within `limit`.
    static func placeLayer(_ src: Surface, _ w: Int, _ h: Int, _ t: CompTransform, format: PixelFormat, limit: PixelRect) -> Placed {
        if t.isPixelAligned(w, h) {
            let grid = PixelRect(x: 0, y: 0, width: w, height: h)
            var s = src.translated(dx: Int32(t.originX), dy: Int32(t.originY), content: grid)
            if s.format != format { s = s.converted(to: format) }
            return Placed(surface: s, resampled: false, cropped: false)
        }
        let full = bounds(t, w, h)
        let box = full.intersect(limit)
        var out = Surface(format: format)
        guard !box.isEmpty else { return Placed(surface: out, resampled: true, cropped: !full.isEmpty) }
        let rgba = src.readRGBA(PixelRect(x: 0, y: 0, width: w, height: h))
        let drawn = draw(rgba: rgba, w, h, t, into: box, hdr: format.sample == .f32)
        out.writeRGBA(box, drawn)
        out.prune()
        return Placed(surface: out, resampled: true, cropped: box != full)
    }

    /// A mask grid (`w` × `h` gray values) stretched over `t`, on the document within `limit`,
    /// with `background` everywhere it doesn't reach.
    static func placeMask(_ values: [Float], _ w: Int, _ h: Int, _ t: CompTransform, background: Float, format: PixelFormat,
                          limit: PixelRect) -> Surface {
        var out = Surface(format: format, defaultPixel: [background])
        // A uniform mask looks the same wherever it sits (Compositor stores 1×1 ones).
        if let first = values.first, values.allSatisfy({ $0 == first }), first == background { return out }
        if t.isPixelAligned(w, h) {
            let grid = PixelRect(x: Int(t.originX), y: Int(t.originY), width: w, height: h)
            out.writeRegion(grid, values)
            out.prune()
            return out
        }
        let box = bounds(t, w, h).intersect(limit)
        guard !box.isEmpty else { return out }
        out.writeRegion(box, drawGray(values, w, h, t, into: box, background: background))
        out.prune()
        return out
    }

    // MARK: CoreGraphics drawing
    //
    // 16-bit contexts: unsigned integers for 8- and 16-bit pixels and masks, half floats for HDR
    // pixels. CoreGraphics' 32-bit float contexts are not used: scaled with interpolation off, they
    // repeat a row's first pixel along the image's last row (macOS 27.2, any colour space).

    /// One colour space for both the image and the context, so CoreGraphics converts nothing.
    /// (Integer contexts take a plain space, float ones an extended one.)
    private static let rgbSpace = CGColorSpace(name: CGColorSpace.linearSRGB)!
    private static let hdrSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private static let graySpace = CGColorSpace(name: CGColorSpace.linearGray)!

    /// The CTM that maps a `box`-sized context onto document pixels (y down) and then does what
    /// `LayerRenderer.draw` does: translate to the box centre, rotate, flip, and draw the image
    /// upright in a `w` × `h` rect around the origin.
    private static func prepare(_ ctx: CGContext, _ t: CompTransform, box: PixelRect) {
        ctx.translateBy(x: 0, y: CGFloat(box.height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: CGFloat(-Int(box.x0)), y: CGFloat(-Int(box.y0)))
        ctx.translateBy(x: CGFloat(t.originX + t.width / 2), y: CGFloat(t.originY + t.height / 2))
        ctx.rotate(by: CGFloat(t.radians))
        ctx.scaleBy(x: t.flipX ? -1 : 1, y: t.flipY ? 1 : -1)
    }

    /// `rgba` (`w` × `h`, straight) drawn through `t` into `box`; `hdr` keeps values above 1.
    static func draw(rgba: [SIMD4<Float>], _ w: Int, _ h: Int, _ t: CompTransform, into box: PixelRect, hdr: Bool = false) -> [SIMD4<Float>] {
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue | (hdr ? CGBitmapInfo.floatComponents.rawValue : 0)
        var src = [UInt16](repeating: 0, count: w * h * 4)
        func store(_ v: Float) -> UInt16 { hdr ? Float16(v).bitPattern : UInt16((min(max(v, 0), 1) * 65535).rounded()) }
        func load(_ b: UInt16) -> Float { hdr ? Float(Float16(bitPattern: b)) : Float(b) / 65535 }
        for (i, p) in rgba.enumerated() {
            let a = min(max(p.w, 0), 1)
            src[i * 4] = store(p.x * a); src[i * 4 + 1] = store(p.y * a); src[i * 4 + 2] = store(p.z * a); src[i * 4 + 3] = store(a)
        }
        let bw = box.width, bh = box.height
        let empty = [SIMD4<Float>](repeating: .zero, count: box.area)
        guard let provider = CGDataProvider(data: Data(bytes: src, count: src.count * 2) as CFData),
              let image = CGImage(width: w, height: h, bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: w * 8, space: hdr ? hdrSpace : rgbSpace,
                                  bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent),
              let ctx = CGContext(data: nil, width: bw, height: bh, bitsPerComponent: 16, bytesPerRow: bw * 8, space: hdr ? hdrSpace : rgbSpace, bitmapInfo: info)
        else { return empty }
        prepare(ctx, t, box: box)
        ctx.interpolationQuality = interpolation(t, w)
        ctx.setShouldAntialias(t.sampling != .nearest)
        ctx.draw(image, in: CGRect(x: -t.width / 2, y: -t.height / 2, width: t.width, height: t.height))
        guard let data = ctx.data else { return empty }
        let f = data.bindMemory(to: UInt16.self, capacity: bw * bh * 4)
        var out = empty
        for i in 0 ..< bw * bh {
            let a = min(max(load(f[i * 4 + 3]), 0), 1)
            out[i] = a > 0 ? SIMD4(load(f[i * 4]) / a, load(f[i * 4 + 1]) / a, load(f[i * 4 + 2]) / a, a) : .zero
        }
        return out
    }

    /// Mask `values` (`w` × `h`, 0–1) drawn through `t` into `box` over `background`.
    static func drawGray(_ values: [Float], _ w: Int, _ h: Int, _ t: CompTransform, into box: PixelRect, background: Float) -> [Float] {
        let info = CGImageAlphaInfo.none.rawValue | CGBitmapInfo.byteOrder16Little.rawValue
        let src = values.map { UInt16((min(max($0, 0), 1) * 65535).rounded()) }
        let bw = box.width, bh = box.height
        let flat = [Float](repeating: background, count: box.area)
        guard let provider = CGDataProvider(data: Data(bytes: src, count: src.count * 2) as CFData),
              let image = CGImage(width: w, height: h, bitsPerComponent: 16, bitsPerPixel: 16, bytesPerRow: w * 2, space: graySpace,
                                  bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent),
              let ctx = CGContext(data: nil, width: bw, height: bh, bitsPerComponent: 16, bytesPerRow: bw * 2, space: graySpace, bitmapInfo: info)
        else { return flat }
        ctx.setFillColor(gray: CGFloat(background), alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: bw, height: bh))
        prepare(ctx, t, box: box)
        ctx.interpolationQuality = t.sampling == .nearest ? .none : (t.sampling == .high ? .high : .low)
        ctx.setShouldAntialias(t.sampling != .nearest)
        ctx.draw(image, in: CGRect(x: -t.width / 2, y: -t.height / 2, width: t.width, height: t.height))
        guard let data = ctx.data else { return flat }
        let f = data.bindMemory(to: UInt16.self, capacity: bw * bh)
        return (0 ..< bw * bh).map { Float(f[$0]) / 65535 }
    }

    // MARK: Colour

    /// The sRGB transfer curve decoded to linear light, mirrored below zero (extended sRGB).
    @inline(__always) static func srgbToLinear(_ v: Float) -> Float {
        let a = abs(v)
        let l = a <= 0.04045 ? a / 12.92 : powf((a + 0.055) / 1.055, 2.4)
        return v < 0 ? -l : l
    }

    /// The sRGB transfer curve encoding linear light, mirrored below zero.
    @inline(__always) static func linearToSRGB(_ v: Float) -> Float {
        let a = abs(v)
        let e = a <= 0.0031308 ? a * 12.92 : 1.055 * powf(a, 1 / 2.4) - 0.055
        return v < 0 ? -e : e
    }

    /// Whether linear float pixels pass white, as Compositor decides it (`DeepLayer.wideAsset`: a
    /// premultiplied sample over 1.001 in extended sRGB, about 1.0024 in linear light).
    static func passesWhite(_ s: Surface, _ w: Int, _ h: Int) -> Bool {
        let limit: Float = 1.0024
        return s.readRGBA(PixelRect(x: 0, y: 0, width: w, height: h)).contains { p in max(p.x, p.y, p.z) * p.w > limit }
    }

    /// Linear float pixels within white as a 16-bit sRGB grid.
    static func encodedSixteen(_ s: Surface, _ w: Int, _ h: Int) -> Surface {
        let r = PixelRect(x: 0, y: 0, width: w, height: h)
        var out = Surface(format: .rgba16)
        out.writeRGBA(r, s.readRGBA(r).map { p in
            SIMD4(min(max(linearToSRGB(p.x), 0), 1), min(max(linearToSRGB(p.y), 0), 1), min(max(linearToSRGB(p.z), 0), 1), min(max(p.w, 0), 1))
        })
        out.prune()
        return out
    }

    /// `s` in `format` (an RGB float format for HDR documents): 8/16-bit sRGB pixels are decoded
    /// to linear light there, float pixels are already linear (OpenEXR).
    static func toDocument(_ s: Surface, _ format: PixelFormat) -> Surface {
        if s.format == format { return s }
        if format.sample == .f32 && s.format.sample != .f32 {
            var out = Surface(format: format)
            let r = s.tileBounds
            guard !r.isEmpty else { return out }
            let px = s.readRGBA(r).map { p in SIMD4(srgbToLinear(p.x), srgbToLinear(p.y), srgbToLinear(p.z), p.w) }
            out.writeRGBA(r, px)
            out.prune()
            return out
        }
        if s.format.mode == format.mode { return s.converted(to: format) }
        var out = Surface(format: format)
        let r = s.tileBounds
        if !r.isEmpty { out.writeRGBA(r, s.readRGBA(r)) }
        out.prune()
        return out
    }
}
