// Shared helpers of the whole-document mapping tests (adjustments, effects, vectors, comps, smart
// objects, type, Affinity export halves): the compositor and renderers photocraft's tests get from
// photocraft-compose / photocraft-vector, export/import with PCPSD's linter, synthetic Affinity
// documents.
// Port of photocraft-io's test helpers (crates/io/tests/common/mod.rs `max_diff`,
// tests/support/current_affinity.rs, the fixtures of tests/affinity.rs), MIT OR Apache-2.0,
// © ArtCraft Team and the PhotoCraft contributors.

import CoreGraphics
import Foundation
import PCAffinitySynth
import PCDocument
import PCFoundation
import PCIOCore
import PCPSD
import PCRender
import Testing
@testable import PCIO

enum MapsKit {
    // MARK: - Rendering

    /// Fill coverage, shape and stroke rasterization through CoreGraphics (antialiased), standing in
    /// for photocraft-vector (PCPlatform owns the engine's). Gradient and pattern paints draw with
    /// their first colour / mid grey: the tests that need them compare a document with its own
    /// round trip.
    struct CGRasterizer: LayerRasterizer {
        func rasterize(_ layer: Layer, in document: Document) -> Surface? {
            guard case let .shape(sh) = layer.content else { return nil }
            return MapsKit.renderShape(sh, format: document.pixelFormat, clip: document.bounds)
        }

        func coverage(of path: VectorPath, in rect: PixelRect) -> [Float]? { MapsKit.coverage(path, rect) }

        func renderShape(_ shape: ShapeLayer, format: PixelFormat, clip: PixelRect) -> Surface? {
            MapsKit.renderShape(shape, format: format, clip: clip)
        }
    }

    /// The injected `LayerContentRenderer` (photocraft always has its vector engine and text
    /// engine): shapes through CoreGraphics; type only when a test gives a text closure (there is
    /// no font renderer here). Fill layers PCIO renders itself (PCRender's `FillLayerRenderer`).
    struct Renderer: LayerContentRenderer {
        var text: (@Sendable (TextLayer, PixelFormat, Float, UInt64) -> Surface?)?
        /// Installed families (nil: every family is installed).
        var families: Set<String>?
        var postscript: [String: ResolvedFont] = [:]

        init(text: (@Sendable (TextLayer, PixelFormat, Float, UInt64) -> Surface?)? = nil, families: Set<String>? = nil,
             postscript: [String: ResolvedFont] = [:]) {
            self.text = text
            self.families = families
            self.postscript = postscript
        }

        func renderShape(_ shape: ShapeLayer, format: PixelFormat, canvas: PixelRect) -> Surface? {
            MapsKit.renderShape(shape, format: format, clip: canvas)
        }

        func renderText(_ text: TextLayer, format: PixelFormat, dpi: Float, maxPixels: UInt64) -> Surface? {
            self.text?(text, format, dpi, maxPixels)
        }

        func hasFontFamily(_ family: String) -> Bool { families?.contains(family) ?? true }
        func resolvePostScript(_ name: String) -> ResolvedFont? { postscript[name] }
    }

    /// Coverage (0…1, row-major over `r`) of `path`: each shape component filled with the path's
    /// fill rule, folded in with its operation, inverted when `path.inverted`.
    static func coverage(_ path: VectorPath, _ r: PixelRect) -> [Float]? {
        let (w, h) = (r.width, r.height)
        guard w > 0, h > 0, w * h <= 1 << 26 else { return nil }
        var acc: [Float]?
        for comp in path.components {
            let cg = CGMutablePath()
            for s in path.subpaths[comp] where !s.knots.isEmpty { cg.addPath(s.cgPath) }
            guard let cov = fillCoverage(cg, path.fillRule.cgFillRule, r) else { return nil }
            guard let a = acc else {
                acc = cov
                continue
            }
            let op = path.effectiveOp(comp.lowerBound)
            acc = zip(a, cov).map { x, y in
                switch op {
                case .combine, .join: x + y - x * y
                case .subtract: x * (1 - y)
                case .intersect: x * y
                case .exclude: x + y - 2 * x * y
                }
            }
        }
        var out = acc ?? [Float](repeating: 0, count: w * h)
        if path.inverted { out = out.map { 1 - $0 } }
        return out
    }

    /// One CoreGraphics fill of `p` (document coordinates) as coverage over `r`.
    static func fillCoverage(_ p: CGPath, _ rule: CGPathFillRule, _ r: PixelRect) -> [Float]? {
        let (w, h) = (r.width, r.height)
        var buf = [UInt8](repeating: 0, count: w * h)
        let ok = buf.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            flip(ctx, r)
            ctx.addPath(p)
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.fillPath(using: rule)
            return true
        }
        return ok ? buf.map { Float($0) / 255 } : nil
    }

    /// Top-left origin, document coordinates.
    static func flip(_ ctx: CGContext, _ r: PixelRect) {
        ctx.translateBy(x: 0, y: CGFloat(r.height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: -CGFloat(r.x0), y: -CGFloat(r.y0))
    }

    static func cgColor(_ f: Fill, opacity: Float) -> CGColor {
        let c: SIMD4<Float>
        switch f {
        case let .solid(p): c = SIMD4(p.rgb, p.alpha)
        case let .gradient(g): c = g.stops.first.map { SIMD4($0.color.rgb, $0.color.alpha) } ?? SIMD4(0, 0, 0, 1)
        case .pattern: c = SIMD4(0.5, 0.5, 0.5, 1)
        }
        return CGColor(srgbRed: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: CGFloat(c.w * opacity))
    }

    /// `shape`'s fill and stroke over `clip` in `format`.
    static func renderShape(_ shape: ShapeLayer, format: PixelFormat, clip: PixelRect) -> Surface? {
        let (w, h) = (clip.width, clip.height)
        guard w > 0, h > 0, w * h <= 1 << 26 else { return Surface(format: format) }
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let path = CGMutablePath()
        for s in shape.path.subpaths where !s.knots.isEmpty { path.addPath(s.cgPath) }
        let rule = shape.path.fillRule.cgFillRule
        let ok = buf.withUnsafeMutableBytes { raw -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            flip(ctx, clip)
            if let f = shape.fill {
                if shape.path.inverted {
                    // The inverted area: everything outside the path.
                    ctx.addRect(clip.cgRect)
                    ctx.addPath(path)
                    ctx.setFillColor(cgColor(f, opacity: 1))
                    ctx.fillPath(using: .evenOdd)
                } else if let cov = coverage(shape.path, clip) {
                    // Path operations need the folded coverage: paint it.
                    let c = cgColor(f, opacity: 1).components ?? [0, 0, 0, 1]
                    let p = raw.bindMemory(to: UInt8.self)
                    for i in 0 ..< w * h where cov[i] > 0 {
                        let a = Double(cov[i]) * Double(c.count > 3 ? c[3] : 1)
                        for k in 0 ..< 3 { p[i * 4 + k] = UInt8((Double(c[k]) * a * 255).rounded()) }
                        p[i * 4 + 3] = UInt8((a * 255).rounded())
                    }
                } else {
                    ctx.addPath(path)
                    ctx.setFillColor(cgColor(f, opacity: 1))
                    ctx.fillPath(using: rule)
                }
            }
            if let s = shape.stroke, s.width > 0, !path.isEmpty {
                let width = CGFloat(s.width)
                ctx.saveGState()
                switch s.align {
                case .center:
                    ctx.setLineWidth(width)
                case .inside:
                    ctx.addPath(path)
                    ctx.clip(using: rule)
                    ctx.setLineWidth(width * 2)
                case .outside:
                    ctx.addRect(clip.cgRect.insetBy(dx: -width * 4, dy: -width * 4))
                    ctx.addPath(path)
                    ctx.clip(using: .evenOdd)
                    ctx.setLineWidth(width * 2)
                }
                ctx.setLineCap(s.cap.cgLineCap)
                ctx.setLineJoin(s.join.cgLineJoin)
                ctx.setMiterLimit(CGFloat(s.miterLimit))
                if !s.dashes.isEmpty, s.dashes.contains(where: { $0 > 0 }) {
                    ctx.setLineDash(phase: CGFloat(s.dashOffset) * width, lengths: s.dashes.map { CGFloat($0) * width })
                }
                ctx.addPath(path)
                ctx.setStrokeColor(cgColor(s.paint, opacity: s.opacity))
                ctx.strokePath()
                ctx.restoreGState()
            }
            return true
        }
        guard ok else { return nil }
        var px = [SIMD4<Float>](repeating: .zero, count: w * h)
        for i in 0 ..< w * h {
            let a = Float(buf[i * 4 + 3]) / 255
            guard a > 0 else { continue }
            px[i] = SIMD4(min(Float(buf[i * 4]) / 255 / a, 1), min(Float(buf[i * 4 + 1]) / 255 / a, 1), min(Float(buf[i * 4 + 2]) / 255 / a, 1), a)
        }
        var s = Surface(format: format)
        s.writeRGBA(clip, px)
        s.prune()
        return s
    }

    private static let flattenLock = NSLock()
    private static let flattener = PCRender.DocumentCompositor(rasterizer: CGRasterizer(), backend: .cpu, metal: nil)

    /// The compositor of the exports (photocraft's merged image comes from photocraft-compose):
    /// PCRender's CPU reference with the CoreGraphics rasterizer.
    static let compositor = RenderCompositor(PCRender.DocumentCompositor(rasterizer: CGRasterizer(), backend: .cpu, metal: nil))

    /// photocraft `photocraft_compose::flatten`: the composite as straight RGBA.
    static func flatten(_ d: Document) throws -> RGBABuffer { try render(d, d.bounds) }

    /// photocraft `photocraft_compose::render` over `r`.
    static func render(_ d: Document, _ r: PixelRect) throws -> RGBABuffer {
        try flattenLock.withLock { try flattener.render(d, region: r) }
    }

    /// One composited pixel (photocraft `render(doc, Rect::from_xywh(x, y, 1, 1)).px[0]`).
    static func pixel(_ d: Document, _ x: Int32, _ y: Int32) throws -> SIMD4<Float> {
        try render(d, PixelRect(x0: x, y0: y, x1: x + 1, y1: y + 1)).px[0]
    }

    /// photocraft `common::max_diff`: max per-channel difference of premultiplied colour and alpha,
    /// over pixels where either side is not fully transparent.
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

    /// photocraft's `ExportOptions::default()`: its record shape (`photoshop: false`), or
    /// Photoshop's (the PCIO default); the CPU compositor and the stand-in renderer.
    static func options(photoshop: Bool = false, renderer: (any LayerContentRenderer)? = Renderer()) -> IOOptions {
        var o = IOOptions(compositor: compositor, renderer: renderer)
        o.photoshopRecordConventions = photoshop
        return o
    }

    /// Error-severity findings of PCPSD's Photoshop-compatibility linter on a written PSD/PSB.
    static func lintErrors(_ bytes: [UInt8]) -> [String] {
        guard let f = try? PSDFile(bytes: bytes) else { return ["unparseable"] }
        return f.compatibilityIssues(decodeChannels: true).filter { $0.severity == .error }.map(\.description)
    }

    /// photocraft `export`; every PSD/PSB written also passes PCPSD's linter. `knownLintIssue`
    /// names a reported PCIO finding that makes the linter fail for this document.
    static func export(_ d: Document, _ name: String = "x.psd", options: IOOptions = options(), knownLintIssue: String? = nil,
                       sourceLocation: SourceLocation = #_sourceLocation) throws -> ExportResult {
        let r = try DocumentIO.export(d, as: name, options: options)
        let ext = DocumentIO.fileExtension(name.contains(".") ? name : "x.\(name)")
        if ext == "psd" || ext == "psb" {
            let errs = lintErrors(r.bytes)
            if let known = knownLintIssue {
                withKnownIssue(Comment(rawValue: known), isIntermittent: true) {
                    #expect(errs.isEmpty, "\(name): linter errors \(errs.prefix(4))", sourceLocation: sourceLocation)
                }
            } else {
                #expect(errs.isEmpty, "\(name): linter errors \(errs.prefix(4))", sourceLocation: sourceLocation)
            }
        }
        return r
    }

    /// photocraft `import`.
    static func importFile(_ bytes: [UInt8], _ name: String = "x.psd", options: IOOptions = options()) throws -> ImportResult {
        try DocumentIO.importFile(name: name, bytes: bytes, options: options)
    }

    /// Export then import.
    static func roundtrip(_ d: Document, _ name: String = "x.psd", options: IOOptions = options(), sourceLocation: SourceLocation = #_sourceLocation) throws -> Document {
        try importFile(export(d, name, options: options, sourceLocation: sourceLocation).bytes, name, options: options).document
    }

    /// photocraft `psd_to_document` with the stand-in renderer.
    static func psdToDocument(_ f: PSDFile, renderer: (any LayerContentRenderer)? = Renderer()) throws -> Document {
        try PSDImport.document(f, options: PSDImportOptions(renderer: renderer)).document
    }

    static func bytes(_ f: PSDFile) throws -> [UInt8] { [UInt8](try f.serialized()) }

    /// photocraft `common::strict_block_errors` (#200): the file parses with nothing left over in
    /// the layer and mask section, global blocks are padded to 4, layer blocks have an even length
    /// with no pad byte outside it, and every block with inner lengths re-parses exactly (PCPSD's
    /// `checkStructure`, run by its linter, whose other errors are included).
    static func strictBlockErrors(_ bytes: [UInt8]) -> [String] {
        let file: PSDFile
        do { file = try PSDFile(bytes: bytes) } catch { return ["parse: \(error)"] }
        var errs = lintErrors(bytes)
        if !file.layerMaskTrailing.isEmpty { errs.append("\(file.layerMaskTrailing.count) unparsed bytes at the end of the layer and mask section") }
        for b in file.globalBlocks {
            let pad = b.padding?.count ?? (4 - b.data.count % 4) % 4
            if (b.data.count + pad) % 4 != 0 { errs.append("global \(b.key): \(b.data.count) data bytes + \(pad) padding is not a multiple of 4") }
        }
        for (i, l) in file.layers.enumerated() {
            for b in l.blocks where b.data.count % 2 != 0 || !(b.padding?.isEmpty ?? true) {
                errs.append("layer \(i) \(b.key): \(b.data.count) data bytes with padding outside the length")
            }
        }
        return errs
    }

    /// Smart-object source placement for regenerated filter caches (PCAlgo's in the engine): whole
    /// pixel translations only.
    static let placeTranslated: @Sendable (Surface, PixelRect, PCAffine, [Double]?, Warp?) -> Surface? = { s, bounds, t, perspective, warp in
        guard perspective == nil, warp == nil, t.a == 1, t.b == 0, t.c == 0, t.d == 1, abs(t.e) < 1e6, abs(t.f) < 1e6,
              t.e == t.e.rounded(), t.f == t.f.rounded() else { return nil }
        return s.translated(dx: Int32(t.e), dy: Int32(t.f), content: bounds)
    }

    /// A layer record's block data by layer name (photocraft `layer_block`).
    static func layerBlock(_ f: PSDFile, _ name: String, _ key: FourCC) -> [UInt8]? {
        f.layers.first { $0.displayName == name }?.block(key).map { [UInt8]($0.data) }
    }

    static func be32(_ d: [UInt8], _ at: Int) -> UInt32 {
        guard at >= 0, at + 4 <= d.count else { return 0 }
        return UInt32(d[at]) << 24 | UInt32(d[at + 1]) << 16 | UInt32(d[at + 2]) << 8 | UInt32(d[at + 3])
    }

    static func beBytes<T: FixedWidthInteger>(_ v: T) -> [UInt8] { Synth.bytesBE(v) }

    // MARK: - Geometry (photocraft_vector::shapes)

    /// `shapes::rect(x, y, w, h)`: a closed rectangle.
    static func rectPath(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> VectorPath {
        VectorPath([Subpath.polygon([(x, y), (x + w, y), (x + w, y + h), (x, y + h)])])
    }

    /// `shapes::ellipse(x, y, w, h)`: four smooth knots with kappa handles, clockwise from the top.
    static func ellipsePath(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> VectorPath {
        let k = 0.5522847498307936
        let (cx, cy, rx, ry) = (x + w / 2, y + h / 2, w / 2, h / 2)
        let knots = [
            Knot.smooth(anchor: PCPoint(cx, y), inCtrl: PCPoint(cx - rx * k, y), outCtrl: PCPoint(cx + rx * k, y)),
            Knot.smooth(anchor: PCPoint(x + w, cy), inCtrl: PCPoint(x + w, cy - ry * k), outCtrl: PCPoint(x + w, cy + ry * k)),
            Knot.smooth(anchor: PCPoint(cx, y + h), inCtrl: PCPoint(cx + rx * k, y + h), outCtrl: PCPoint(cx - rx * k, y + h)),
            Knot.smooth(anchor: PCPoint(x, cy), inCtrl: PCPoint(x, cy + ry * k), outCtrl: PCPoint(x, cy - ry * k)),
        ]
        return VectorPath([Subpath(closed: true, knots: knots, op: .combine)])
    }

    /// A shape layer with its cache rendered over `canvas` (photocraft `render_shape` + `Layer::new`).
    static func shapeLayer(_ name: String, _ sh: ShapeLayer, format: PixelFormat = .rgba8, canvas: PixelRect) -> Layer {
        var sh = sh
        sh.cache = renderShape(sh, format: format, clip: canvas)
        return Layer(name: name, content: .shape(sh))
    }

    // MARK: - Synthetic Affinity documents (photocraft-affinity `synth`, tests/affinity.rs)

    typealias F = Synth.F
    typealias Tag = Synth.Tag

    static let affinityMagic: [UInt8] = [0x00, 0xFF, 0x4B, 0x41]

    static func le<T: FixedWidthInteger>(_ v: T) -> [UInt8] { Synth.bytesLE(v) }

    /// One PNG chunk: length, type, data, CRC.
    static func chunk(_ kind: String, _ data: [UInt8]) -> [UInt8] {
        let tagged = Array(kind.utf8) + data
        return Synth.bytesBE(UInt32(data.count)) + tagged + Synth.bytesBE(Synth.crc32(tagged))
    }

    /// A plain PNG (IHDR, one IDAT, IEND) of unfiltered scanlines.
    static func makePNG(width: UInt32, height: UInt32, bitDepth: UInt8, colorType: UInt8, rows: [[UInt8]]) -> [UInt8] {
        var png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        png += chunk("IHDR", Synth.bytesBE(width) + Synth.bytesBE(height) + [bitDepth, colorType, 0, 0, 0])
        png += chunk("IDAT", Synth.zlib(rows.flatMap { [0] + $0 }))
        png += chunk("IEND", [])
        return png
    }

    /// The 2×1 RGBA8 PNG of tests/affinity.rs: an opaque red-ish pixel and a transparent one.
    static func png() -> [UInt8] {
        makePNG(width: 2, height: 1, bitDepth: 8, colorType: 6, rows: [[220, 40, 60, 255, 0, 0, 0, 0]])
    }

    /// A synthetic preview record envelope (tests/affinity.rs `file`), not an Affinity writer.
    static func previewFile(_ png: [UInt8]) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 72)
        b.replaceSubrange(0 ..< 4, with: affinityMagic)
        b.replaceSubrange(4 ..< 6, with: le(UInt16(12)))
        b.replaceSubrange(8 ..< 12, with: Array("nsrP".utf8))
        b.replaceSubrange(12 ..< 16, with: Array("#Inf".utf8))
        b.replaceSubrange(24 ..< 32, with: le(UInt64(72)))
        b.replaceSubrange(64 ..< 68, with: Array("Prot".utf8))
        b += [0xFF, 0xFF, 0xFF, 0xFF] + Array("Thmb".utf8)
        b += le(UInt32(1)) + le(UInt32(png.count + 13)) + le(UInt32(29)) + le(UInt32(0)) + le(UInt32(png.count))
        b.append(1)
        b += png
        return b
    }

    static func rgba(_ r: Float, _ g: Float, _ b: Float, _ a: Float) -> F {
        .structure([r, g, b, a].flatMap { le($0.bitPattern) })
    }

    /// A fill descriptor holding a solid RGBA colour: ids `id`, `id + 1`, `id + 2`.
    static func solid(_ id: UInt32, _ c: F) -> F {
        .def(id, ["FDsc"], [("FDeF", .def(id + 1, ["FilS"], [("Colr", .def(id + 2, ["RGBA"], [("_col", c)]))]))])
    }

    /// One 18-byte curve record: an anchor at (x, y).
    static func anchor(_ x: Double, _ y: Double) -> [UInt8] {
        le(x.bitPattern) + le(y.bitPattern) + [1, 0]
    }

    static func stream(_ spreads: [F], dpi: Double = 144) -> [UInt8] {
        Synth.stream([
            ("UVCn", .obj("UVCn", [("UPPI", .f64(dpi))])),
            ("DocR", .def(1, ["DocN"], [("Chld", .shared(spreads))])),
        ])
    }

    static func spread(_ id: UInt32, _ children: [F], bounds: [Double] = [0, 0, 200, 100]) -> F {
        .def(id, ["Sprd"], [("SprB", .f64s(bounds)), ("SprT", .bool(true)), ("Chld", .shared(children))])
    }

    /// tests/affinity.rs `mod native` `document`: version 12 at 144 ppi, 200×100, an artboard
    /// "Board" moved by (20, 10) holding a red ring with a 4 px blue stroke; the 2×1 PNG preview.
    static func ringDocument(_ method: Synth.Method) -> [UInt8] {
        func square(_ s: Double, _ o: Double) -> [[UInt8]] {
            [anchor(o, o), anchor(o + s, o), anchor(o + s, o + s), anchor(o, o + s), anchor(o, o)]
        }
        let ring: F = .def(20, ["PCrv"], [
            ("Desc", .str("Ring")),
            ("Crvs", .obj("PCvD", [("Data", .pos([.u8(0), .u32(2), .bool(true), .records(18, square(60, 0)), .bool(true), .records(18, square(20, 20))]))])),
            ("BFFl", .shared([solid(21, rgba(1, 0, 0, 1))])),
            ("LIFl", .shared([solid(24, rgba(0, 0, 1, 1))])),
            ("LILn", .shared([.def(27, ["LDsc"], [("LDeL", .def(28, ["LSty"], [("Wght", .f64(4))]))])])),
        ])
        let board: F = .def(10, ["ShpN"], [
            ("Desc", .str("Board")),
            ("ABEn", .bool(true)),
            ("Shpe", .def(11, ["ShNR"], [])),
            ("ShpB", .f64s([0, 0, 120, 80])),
            ("Xfrm", .f64s([1, 0, 20, 0, 1, 10])),
            ("BFFl", .shared([solid(12, rgba(1, 1, 1, 1))])),
            ("Chld", .shared([ring])),
        ])
        return Synth.container([("doc.dat", stream([spread(2, [board])]), method)], thumbnailPNG: png())
    }

    /// tests/support/current_affinity.rs: how a board says it is one.
    enum Marker { case legacy, current, otherProperties }

    /// tests/support/current_affinity.rs `document`: two 16 px boards at x = 0 and 24 on a 40×16
    /// spread, each holding a red square that overflows it by 4 px on every side.
    static func boardsDocument(_ marker: Marker, curve: Bool, _ method: Synth.Method) -> [UInt8] {
        func board(_ id: UInt32, _ x: Double) -> F {
            let child: F = .def(id + 10, ["ShpN"], [
                ("Desc", .str("Overflow")),
                ("Shpe", .def(id + 11, ["ShNR"], [])),
                ("ShpB", .f64s([-4, -4, 20, 20])),
                ("BFFl", .shared([solid(id + 12, rgba(1, 0, 0, 1))])),
            ])
            var fields: [(Tag, F)] = [
                ("Desc", .str("Board \(id)")),
                ("Shpe", .def(id + 1, ["ShNR"], [])),
                ("ShpB", .f64s([0, 0, 16, 16])),
                ("Xfrm", .f64s([1, 0, x, 0, 1, 0])),
                ("Chld", .shared([child])),
            ]
            switch marker {
            case .legacy:
                fields.append(("ABEn", .bool(true)))
            case .current, .otherProperties:
                fields.append(("ABEn", .bool(false)))
                fields.append(("phrp", .def(id + 2, [marker == .current ? "aprp" : "prps"], [])))
            }
            return .def(id, [curve ? "PCrv" : "ShpN"], fields)
        }
        let s = stream([spread(2, [board(100, 0), board(200, 24)], bounds: [0, 0, 40, 16])])
        return Synth.container([("doc.dat", s, method)])
    }
}
