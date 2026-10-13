// Port of photocraft-compose (crates/compose/src/tests.rs helpers) and photocraft-vector (path coverage, for tests), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// End-to-end helpers: documents built from PCDocument values, rendered through the planner by the
// CPU reference and by Metal, with every render's CPU-vs-GPU difference checked and recorded.

import CoreGraphics
import Foundation
import Testing
import PCDocument
import PCFoundation
@testable import PCRender

/// A CoreGraphics `LayerRasterizer` for tests (PCPlatform ships the real one): path coverage and
/// solid-colour shapes; type layers are rendered as a filled box of `textColor` over the layer's
/// transform origin (enough to exercise the uncached-layer path).
final class CGRasterizer: LayerRasterizer, @unchecked Sendable {
    func rasterize(_ layer: Layer, in document: Document) -> Surface? {
        guard case .text(let t) = layer.content else { return nil }
        var s = Surface(format: PixelFormat(mode: .rgb, sample: .u8, alpha: true))
        let x = Int32(t.transform.e), y = Int32(t.transform.f)
        s.fill(PixelRect(x0: x, y0: y, x1: x + Int32(max(t.text.count, 1)) * 6, y1: y + Int32(max(t.sizePt, 1))), with: [t.color.rgb.x, t.color.rgb.y, t.color.rgb.z, 1])
        return s
    }

    func coverage(of path: VectorPath, in rect: PixelRect) -> [Float]? {
        let (w, h) = (rect.width, rect.height)
        if w == 0 || h == 0 { return [] }
        var buf = [UInt8](repeating: 0, count: w * h)
        buf.withUnsafeMutableBytes { p in
            guard let ctx = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)
            ctx.translateBy(x: -CGFloat(rect.x0), y: -CGFloat(rect.y0))
            let cg = CGMutablePath()
            for sp in path.subpaths { cg.addPath(sp.cgPath) }
            ctx.addPath(cg)
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.fillPath(using: path.fillRule.cgFillRule)
        }
        return buf.map { path.inverted ? 1 - Float($0) / 255 : Float($0) / 255 }
    }

    func renderShape(_ shape: ShapeLayer, format: PixelFormat, clip: PixelRect) -> Surface? {
        guard let b = shape.path.controlBounds else { return Surface(format: format) }
        let pad = Double((shape.stroke?.width ?? 0) + 2)
        let area = PixelRect(x0: Int32((b.x - pad).rounded(.down)), y0: Int32((b.y - pad).rounded(.down)),
                             x1: Int32((b.z + pad).rounded(.up)), y1: Int32((b.w + pad).rounded(.up))).intersect(clip)
        if area.isEmpty { return Surface(format: format) }
        let (w, h) = (area.width, area.height)
        var buf = [Float](repeating: 0, count: w * h * 4)
        // Gradient fills: the fill ramp over the shape's whole-pixel bounds × the path coverage
        // (premultiplied, before CoreGraphics draws the stroke on top).
        if let f = shape.fill, let cov = coverage(of: shape.path, in: area) {
            var align = true
            if case .gradient(let g) = f { align = g.align }
            let frame = align ? PixelRect(x0: Int32(b.x.rounded(.down)), y0: Int32(b.y.rounded(.down)), x1: Int32(b.z.rounded(.up)), y1: Int32(b.w.rounded(.up)))
                              : clip
            // Solid colours too: CoreGraphics clamps colours to 0…1 (HDR fills keep their values here).
            let px = FillRender.render(f, rect: area, frame: frame, quantum: nil, source: LeafTable()).px
            for i in 0..<(w * h) {
                let o = i * 4
                let a = px[i].w * cov[i]
                buf[o] = px[i].x * a; buf[o + 1] = px[i].y * a; buf[o + 2] = px[i].z * a; buf[o + 3] = a
            }
        }
        buf.withUnsafeMutableBytes { p in
            guard let ctx = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 32, bytesPerRow: w * 16,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue
                                        | CGBitmapInfo.byteOrder32Little.rawValue) else { return }
            ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)
            ctx.translateBy(x: -CGFloat(area.x0), y: -CGFloat(area.y0))
            let cg = CGMutablePath()
            for sp in shape.path.subpaths { cg.addPath(sp.cgPath) }
            if let st = shape.stroke, case .solid(let c) = st.paint, st.width > 0 {
                ctx.saveGState()
                let wide = st.align == .center ? CGFloat(st.width) : CGFloat(st.width) * 2
                switch st.align {
                case .inside:
                    ctx.addPath(cg); ctx.clip(using: shape.path.fillRule.cgFillRule)
                case .outside:
                    let outer = CGMutablePath()
                    outer.addRect(CGRect(x: CGFloat(area.x0) - 10, y: CGFloat(area.y0) - 10, width: CGFloat(w) + 20, height: CGFloat(h) + 20))
                    outer.addPath(cg)
                    ctx.addPath(outer); ctx.clip(using: .evenOdd)
                case .center: break
                }
                ctx.addPath(cg)
                ctx.setLineWidth(wide)
                ctx.setStrokeColor(red: CGFloat(c.rgb.x), green: CGFloat(c.rgb.y), blue: CGFloat(c.rgb.z), alpha: CGFloat(c.alpha * st.opacity))
                ctx.strokePath()
                ctx.restoreGState()
            }
        }
        var data = [Float](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) {
            let a = buf[i * 4 + 3]
            if a > 0 { for k in 0..<3 { data[i * 4 + k] = buf[i * 4 + k] / a } }
            data[i * 4 + 3] = a
        }
        var rgba = Surface(format: PixelFormat(mode: .rgb, sample: .f32, alpha: true))
        rgba.writeRegion(area, data)
        if format == rgba.format { return rgba }
        var out = Surface(format: format)
        out.writeRegion(area, rgba.readRegion(area))
        return out
    }
}

/// Parity statistics of every end-to-end render (printed by `ParityReport`).
final class ParityLog: @unchecked Sendable {
    static let shared = ParityLog()
    private let lock = NSLock()
    private(set) var worst: [String: Float] = [:]
    func record(_ name: String, _ d: Float) {
        lock.lock(); worst[name] = max(worst[name] ?? 0, d); lock.unlock()
    }
}

enum DT {
    static let rasterizer = CGRasterizer()
    /// CPU reference (256² tiles, as photocraft's `render`).
    static let cpu = DocumentCompositor(rasterizer: rasterizer, backend: .cpu, metal: nil)
    /// Metal with the production accumulator precision and small page cells (several per test).
    static let gpu: DocumentCompositor? = (try? MetalCompositor(chunkSize: 512)).map {
        DocumentCompositor(rasterizer: rasterizer, backend: .metal, metal: $0)
    }

    static let rgba8 = PixelFormat(mode: .rgb, sample: .u8, alpha: true)

    static func docWhite(_ w: Int, _ h: Int, mode: ColorMode = .rgb, depth: SampleType = .u8) -> Document {
        Document.withBackground(name: "t", size: PixelSize(width: w, height: h), mode: mode, depth: depth, fill: .white)
    }

    static func solidLayer(_ name: String, _ r: PixelRect, _ rgba: SIMD4<Float>, format: PixelFormat = rgba8) -> Layer {
        var l = Layer.raster(name, format: format)
        l.withRaster { $0.fill(r, with: format.components(fromRGBA: rgba)) }
        return l
    }

    static func rect(_ x0: Int32, _ y0: Int32, _ x1: Int32, _ y1: Int32) -> PixelRect { PixelRect(x0: x0, y0: y0, x1: x1, y1: y1) }

    static func adjustment(_ a: Adjustment) -> Layer { Layer(name: "adj", content: .adjustment(a)) }

    /// CPU render of `region` (default: the canvas), checked against Metal within `tol` (relative
    /// above 1 for HDR values).
    static func render(_ d: Document, _ region: PixelRect? = nil, tol: Float = 1.0 / 255, name: String = #function,
                       sourceLocation: SourceLocation = #_sourceLocation) -> RGBABuffer {
        let r = region ?? d.bounds
        let c: RGBABuffer
        do { c = try cpu.render(d, region: r) } catch {
            Issue.record("CPU render failed: \(error)", sourceLocation: sourceLocation)
            return RGBABuffer(transparent: r)
        }
        if let gpu {
            do {
                let g = try gpu.render(d, region: r)
                let m = maxDiff(c, g)
                ParityLog.shared.record(name, m.d)
                if ProcessInfo.processInfo.environment["PCRENDER_PARITY_LOG"] != nil { print("parity-e2e \(name) \(m.d * 255)") }
                #expect(m.d <= tol, "\(name): GPU vs CPU \(m.d * 255) levels at \(m.at): cpu \(c.px[m.i]) gpu \(g.px[m.i])", sourceLocation: sourceLocation)
            } catch {
                Issue.record("GPU render failed: \(error)", sourceLocation: sourceLocation)
            }
        }
        return c
    }

    /// Largest difference (relative for values above 1), where and its index.
    static func maxDiff(_ a: RGBABuffer, _ b: RGBABuffer) -> (d: Float, at: (Int32, Int32), i: Int) {
        var m: Float = 0, at = 0
        for i in a.px.indices {
            for c in 0..<4 {
                let x = a.px[i][c], y = b.px[i][c]
                var d = abs(x - y) / max(1, abs(x), abs(y))
                if d.isNaN { d = .infinity }
                if d > m { m = d; at = i }
            }
        }
        let w = max(a.rect.width, 1)
        return (m, (a.rect.x0 + Int32(at % w), a.rect.y0 + Int32(at / w)), at)
    }

    /// One pixel of the canvas composite.
    static func px(_ d: Document, _ x: Int32, _ y: Int32, name: String = #function, sourceLocation: SourceLocation = #_sourceLocation) -> SIMD4<Float> {
        render(d, name: name, sourceLocation: sourceLocation).get(x, y)
    }

    static func close4(_ a: SIMD4<Float>, _ b: SIMD4<Float>, _ e: Float = 2.0 / 255) -> Bool {
        (0..<4).allSatisfy { abs(a[$0] - b[$0]) <= e }
    }

    static func rgba(_ r: Float, _ g: Float, _ b: Float, _ a: Float = 1) -> SIMD4<Float> { SIMD4(r, g, b, a) }
    static let white = SIMD4<Float>(1, 1, 1, 1)
    static let black = SIMD4<Float>(0, 0, 0, 1)
    static let clear = SIMD4<Float>(0, 0, 0, 0)

    static func polygon(_ pts: [(Double, Double)]) -> VectorPath { VectorPath([Subpath.polygon(pts)]) }

    /// `fx_doc`: a 40² white document with a red 20² square carrying `effects`.
    static func fxDoc(_ effects: [Effect]) -> Document {
        var d = docWhite(40, 40)
        var l = solidLayer("sq", rect(10, 10, 30, 30), rgba(1, 0, 0))
        l.effects.items = effects
        d.layers.append(l)
        return d
    }

    static func stroke(_ size: Float, _ position: StrokePosition, color: PCColor = .rgb(0, 0, 1)) -> Effect {
        .stroke(StrokeFx(common: FxCommon(.normal, 1), size: size, position: position, paint: .color(color)))
    }

    static func shadow(_ distance: Float, _ angle: Float, spread: Float = 1, size: Float = 0, knocksOut: Bool = true, global: Bool = false) -> Shadow {
        Shadow(common: FxCommon(.normal, 1), color: .black, angle: angle, useGlobalLight: global, distance: distance, spread: spread, size: size,
               contour: .linear, antiAlias: false, noise: 0, knocksOut: knocksOut)
    }

    static func glow(_ technique: GlowTechnique, _ source: GlowSource, paint: FxPaint = .color(.rgb(0, 1, 0)), size: Float = 4) -> Glow {
        Glow(common: FxCommon(.normal, 1), paint: paint, technique: technique, spread: 0, size: size, contour: .linear, antiAlias: false,
             range: 0.5, jitter: 0, noise: 0, source: source)
    }

    static func range(_ black: SIMD2<UInt8>, _ white: SIMD2<UInt8>) -> BlendRange { BlendRange(black: black, white: white) }
}
