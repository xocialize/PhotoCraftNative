// PDF: read pages rasterised at any DPI and depth, import page vectors as paths, extract text, and
// write multi-page PDFs (raster pages, or true vector pages from shapes).
// Fills photocraft's gap #2541 / FILE-215-10 (no Photoshop PDF read, raster-only single-page write)
// with CoreGraphics' PDF engine (CGPDFDocument, CGPDFScanner, CGContext PDF) and PDFKit. Ports
// photocraft's PDF export API shape (crates/io), MIT OR Apache-2.0, © ArtCraft Team and the
// PhotoCraft contributors.
//
// media-bridge's ImageBridge rasterises PDF pages too (`PDFRasterizer`, internal): 8-bit premultiplied
// sRGB BGRA, flattened on white. `rasterizeViaImageBridge(url:)` calls it; `rasterize` here adds
// 16-bit / float output, transparency, and in-memory data.

import CoreGraphics
import Foundation
import PCDocument
import PCFoundation
import PDFKit

/// A filled and/or stroked path found on a PDF page (y down, document pixels at the chosen DPI),
/// as PCDocument's `VectorPath`.
public struct PDFVectorShape: Sendable {
    public var path: VectorPath
    public var fill: PCColor?
    public var stroke: PCColor?
    public var lineWidth: Double

    /// The shape as a document shape layer (solid fill and centred stroke).
    public var shapeLayer: ShapeLayer {
        ShapeLayer(path: path, fill: fill.map { .solid($0) },
                   stroke: stroke.map { ShapeStroke(width: Float(lineWidth), paint: .solid($0)) })
    }
}

/// One page to write.
public struct PDFPageSpec: Sendable {
    /// Page size in pixels at `dpi`.
    public var width: Int
    public var height: Int
    public var dpi: Double
    public var raster: RasterBuffer?
    public var profile: ICCProfile?
    /// Document shape layers drawn over the raster (document pixels, y down). Solid paints stay
    /// vectors; gradient or pattern paints are rasterised at the page resolution.
    public var shapes: [ShapeLayer]

    public init(width: Int, height: Int, dpi: Double = 72, raster: RasterBuffer? = nil, profile: ICCProfile? = nil, shapes: [ShapeLayer] = []) {
        self.width = width; self.height = height; self.dpi = dpi; self.raster = raster; self.profile = profile; self.shapes = shapes
    }
}

public enum PDFDocumentIO {
    static func document(_ data: Data) throws -> CGPDFDocument {
        guard let provider = CGDataProvider(data: data as CFData), let doc = CGPDFDocument(provider), doc.numberOfPages > 0 else {
            throw PlatformError.decodeFailed("not a readable PDF")
        }
        if doc.isEncrypted && !doc.isUnlocked { throw PlatformError.unsupported("encrypted PDF") }
        return doc
    }

    public static func pageCount(data: Data) throws -> Int { try document(data).numberOfPages }

    static func pixelSize(_ page: CGPDFPage, dpi: Double) -> (Int, Int) {
        let box = page.getBoxRect(.cropBox), s = dpi / 72
        let swap = page.rotationAngle % 180 != 0
        return (max(1, Int(((swap ? box.height : box.width) * s).rounded())), max(1, Int(((swap ? box.width : box.height) * s).rounded())))
    }

    /// Every page's pixel size at `dpi` (crop box, /Rotate applied).
    public static func pageSizes(data: Data, dpi: Double) throws -> [PixelSize] {
        let doc = try document(data)
        return (1...doc.numberOfPages).compactMap { doc.page(at: $0) }.map { let (w, h) = pixelSize($0, dpi: dpi); return PixelSize(width: w, height: h) }
    }

    /// Rasterises page `page` (0-based) at `dpi` into sRGB RGBA at `sample` depth; `transparent`
    /// keeps the page's own transparency instead of flattening onto white.
    public static func rasterize(data: Data, page: Int = 0, dpi: Double = 150, sample: SampleType = .u8, transparent: Bool = false) throws -> RasterBuffer {
        let doc = try document(data)
        guard let pg = doc.page(at: page + 1) else { throw PlatformError.invalidArgument("page \(page) of \(doc.numberOfPages)") }
        let (w, h) = pixelSize(pg, dpi: dpi)
        let bpc = sample.bits
        var info = CGImageAlphaInfo.premultipliedLast.rawValue
        if sample == .u16 { info |= CGBitmapInfo.byteOrder16Little.rawValue }
        if sample == .f32 { info |= CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue }
        let space = sample == .f32 ? CGColorSpace(name: CGColorSpace.extendedSRGB)! : CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: bpc, bytesPerRow: w * 4 * sample.bytes, space: space, bitmapInfo: info) else {
            throw PlatformError.frameworkFailure("PDF bitmap context \(w)×\(h)")
        }
        if !transparent {
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        }
        // Scale points → pixels, then let the page fit itself 1:1 (getDrawingTransform never scales
        // up — the trap ImageBridge's rasteriser documents).
        let box = pg.getBoxRect(.cropBox), s = dpi / 72
        let rotated = pg.rotationAngle % 180 != 0
        ctx.scaleBy(x: s, y: s)
        ctx.concatenate(pg.getDrawingTransform(.cropBox, rect: CGRect(x: 0, y: 0, width: rotated ? box.height : box.width, height: rotated ? box.width : box.height),
                                               rotate: 0, preserveAspectRatio: true))
        ctx.clip(to: box)
        ctx.drawPDFPage(pg)
        guard let img = ctx.makeImage() else { throw PlatformError.frameworkFailure("PDF page image") }
        var r = try SurfaceBridge.raster(from: img)
        if sample == .f32 {
            // Tag as plain sRGB floats (extended sRGB uses the same curve within 0…1).
            r = RasterBuffer(width: r.width, height: r.height, format: r.format, bytes: r.bytes)
        }
        return r
    }

    /// Every page through media-bridge's ImageBridge rasteriser (8-bit sRGB, flattened on white).
    public static func rasterizeViaImageBridge(url: URL, dpi: Double = 150) throws -> [RasterBuffer] {
        try ImageCodecs.decodeDisplay8(url: url, pdfDPI: dpi)
    }

    /// The text of page `page` (PDFKit).
    public static func text(data: Data, page: Int = 0) -> String? {
        PDFDocument(data: data)?.page(at: page)?.string
    }

    // MARK: Vector import

    private final class ScanState {
        var ctm = CGAffineTransform.identity
        var fill: PCColor = .black
        var stroke: PCColor = .black
        var lineWidth: Double = 1
        var stack: [(CGAffineTransform, PCColor, PCColor, Double)] = []
        var path = CGMutablePath()
        var current = CGPoint.zero
        var shapes: [PDFVectorShape] = []
        var page = CGAffineTransform.identity
        var lineScale = 1.0
    }

    /// The page's filled and stroked paths (path construction, painting, `q`/`Q`/`cm`, gray/RGB/CMYK
    /// colours and line width), mapped to document pixels at `dpi` (y down). Text, images, shadings
    /// and clipping are not imported.
    public static func vectorShapes(data: Data, page: Int = 0, dpi: Double = 72) throws -> [PDFVectorShape] {
        let doc = try document(data)
        guard let pg = doc.page(at: page + 1) else { throw PlatformError.invalidArgument("page \(page)") }
        let state = ScanState()
        let box = pg.getBoxRect(.cropBox), s = dpi / 72
        state.page = CGAffineTransform(a: s, b: 0, c: 0, d: -s, tx: -box.minX * s, ty: box.maxY * s)
        state.lineScale = s
        guard let table = CGPDFOperatorTableCreate() else { throw PlatformError.frameworkFailure("operator table") }
        func st(_ info: UnsafeMutableRawPointer?) -> ScanState { Unmanaged<ScanState>.fromOpaque(info!).takeUnretainedValue() }
        func nums(_ sc: CGPDFScannerRef, _ n: Int) -> [Double] {
            var out = [Double](repeating: 0, count: n)
            for i in (0..<n).reversed() { var v: CGPDFReal = 0; _ = CGPDFScannerPopNumber(sc, &v); out[i] = Double(v) }
            return out
        }
        func pt(_ s: ScanState, _ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x, y: y).applying(s.ctm) }
        func paint(_ s: ScanState, fill: Bool, stroke: Bool, evenOdd: Bool, close: Bool) {
            if close { s.path.closeSubpath() }
            if (fill || stroke), !s.path.isEmpty {
                var p = VectorPath(cgPath: s.path.copy(using: [s.page]) ?? s.path, fillRule: evenOdd ? .evenOdd : .nonZero)
                if !fill { for i in p.subpaths.indices where !p.subpaths[i].closed { p.subpaths[i].closed = false } }
                let scale = (abs(s.ctm.a * s.ctm.d - s.ctm.b * s.ctm.c)).squareRoot()
                s.shapes.append(PDFVectorShape(path: p, fill: fill ? s.fill : nil, stroke: stroke ? s.stroke : nil, lineWidth: s.lineWidth * Double(scale) * s.lineScale))
            }
            s.path = CGMutablePath()
        }
        CGPDFOperatorTableSetCallback(table, "q") { _, i in let s = st(i); s.stack.append((s.ctm, s.fill, s.stroke, s.lineWidth)) }
        CGPDFOperatorTableSetCallback(table, "Q") { _, i in let s = st(i); if let t = s.stack.popLast() { (s.ctm, s.fill, s.stroke, s.lineWidth) = t } }
        CGPDFOperatorTableSetCallback(table, "cm") { sc, i in
            let s = st(i), v = nums(sc, 6)
            s.ctm = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5]).concatenating(s.ctm)
        }
        CGPDFOperatorTableSetCallback(table, "w") { sc, i in st(i).lineWidth = nums(sc, 1)[0] }
        CGPDFOperatorTableSetCallback(table, "m") { sc, i in let s = st(i), v = nums(sc, 2); s.current = pt(s, v[0], v[1]); s.path.move(to: s.current) }
        CGPDFOperatorTableSetCallback(table, "l") { sc, i in let s = st(i), v = nums(sc, 2); s.current = pt(s, v[0], v[1]); s.path.addLine(to: s.current) }
        CGPDFOperatorTableSetCallback(table, "c") { sc, i in
            let s = st(i), v = nums(sc, 6)
            s.current = pt(s, v[4], v[5]); s.path.addCurve(to: s.current, control1: pt(s, v[0], v[1]), control2: pt(s, v[2], v[3]))
        }
        CGPDFOperatorTableSetCallback(table, "v") { sc, i in
            let s = st(i), v = nums(sc, 4), c1 = s.current
            s.current = pt(s, v[2], v[3]); s.path.addCurve(to: s.current, control1: c1, control2: pt(s, v[0], v[1]))
        }
        CGPDFOperatorTableSetCallback(table, "y") { sc, i in
            let s = st(i), v = nums(sc, 4)
            let e = pt(s, v[2], v[3]); s.path.addCurve(to: e, control1: pt(s, v[0], v[1]), control2: e); s.current = e
        }
        CGPDFOperatorTableSetCallback(table, "h") { _, i in st(i).path.closeSubpath() }
        CGPDFOperatorTableSetCallback(table, "re") { sc, i in
            let s = st(i), v = nums(sc, 4)
            s.path.move(to: pt(s, v[0], v[1])); s.path.addLine(to: pt(s, v[0] + v[2], v[1]))
            s.path.addLine(to: pt(s, v[0] + v[2], v[1] + v[3])); s.path.addLine(to: pt(s, v[0], v[1] + v[3])); s.path.closeSubpath()
        }
        CGPDFOperatorTableSetCallback(table, "f") { _, i in paint(st(i), fill: true, stroke: false, evenOdd: false, close: false) }
        CGPDFOperatorTableSetCallback(table, "F") { _, i in paint(st(i), fill: true, stroke: false, evenOdd: false, close: false) }
        CGPDFOperatorTableSetCallback(table, "f*") { _, i in paint(st(i), fill: true, stroke: false, evenOdd: true, close: false) }
        CGPDFOperatorTableSetCallback(table, "B") { _, i in paint(st(i), fill: true, stroke: true, evenOdd: false, close: false) }
        CGPDFOperatorTableSetCallback(table, "B*") { _, i in paint(st(i), fill: true, stroke: true, evenOdd: true, close: false) }
        CGPDFOperatorTableSetCallback(table, "b") { _, i in paint(st(i), fill: true, stroke: true, evenOdd: false, close: true) }
        CGPDFOperatorTableSetCallback(table, "b*") { _, i in paint(st(i), fill: true, stroke: true, evenOdd: true, close: true) }
        CGPDFOperatorTableSetCallback(table, "S") { _, i in paint(st(i), fill: false, stroke: true, evenOdd: false, close: false) }
        CGPDFOperatorTableSetCallback(table, "s") { _, i in paint(st(i), fill: false, stroke: true, evenOdd: false, close: true) }
        CGPDFOperatorTableSetCallback(table, "n") { _, i in st(i).path = CGMutablePath() }
        CGPDFOperatorTableSetCallback(table, "g") { sc, i in st(i).fill = .gray(Float(nums(sc, 1)[0])) }
        CGPDFOperatorTableSetCallback(table, "G") { sc, i in st(i).stroke = .gray(Float(nums(sc, 1)[0])) }
        CGPDFOperatorTableSetCallback(table, "rg") { sc, i in let v = nums(sc, 3); st(i).fill = .rgb(Float(v[0]), Float(v[1]), Float(v[2])) }
        CGPDFOperatorTableSetCallback(table, "RG") { sc, i in let v = nums(sc, 3); st(i).stroke = .rgb(Float(v[0]), Float(v[1]), Float(v[2])) }
        CGPDFOperatorTableSetCallback(table, "k") { sc, i in let v = nums(sc, 4).map(Float.init); st(i).fill = PCColor(mode: .cmyk, c: SIMD4(v[0], v[1], v[2], v[3])) }
        CGPDFOperatorTableSetCallback(table, "K") { sc, i in let v = nums(sc, 4).map(Float.init); st(i).stroke = PCColor(mode: .cmyk, c: SIMD4(v[0], v[1], v[2], v[3])) }
        // General colour operators (what CoreGraphics itself writes: `cs` + `sc`/`scn`): the operand
        // count gives the model (1 gray, 3 RGB, 4 CMYK); patterns are skipped.
        func color(_ sc: CGPDFScannerRef) -> PCColor? {
            var vals: [Double] = []
            var v: CGPDFReal = 0
            while vals.count < 5, CGPDFScannerPopNumber(sc, &v) { vals.insert(Double(v), at: 0) }
            switch vals.count {
            case 1: return .gray(Float(vals[0]))
            case 3: return .rgb(Float(vals[0]), Float(vals[1]), Float(vals[2]))
            case 4: return PCColor(mode: .cmyk, c: SIMD4(Float(vals[0]), Float(vals[1]), Float(vals[2]), Float(vals[3])))
            default: return nil
            }
        }
        for op in ["sc", "scn"] { CGPDFOperatorTableSetCallback(table, op) { sc, i in if let c = color(sc) { st(i).fill = c } } }
        for op in ["SC", "SCN"] { CGPDFOperatorTableSetCallback(table, op) { sc, i in if let c = color(sc) { st(i).stroke = c } } }
        let stream = CGPDFContentStreamCreateWithPage(pg)
        let info = Unmanaged.passUnretained(state).toOpaque()
        let scanner = CGPDFScannerCreate(stream, table, info)
        CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
        CGPDFContentStreamRelease(stream)
        CGPDFOperatorTableRelease(table)
        return state.shapes
    }

    // MARK: Write

    /// A multi-page raster PDF, each page `width × height` pixels at `dpi`.
    public static func writeRaster(pages: [RasterBuffer], profile: ICCProfile?, dpi: Double) throws -> Data {
        try write(pages: pages.map { PDFPageSpec(width: $0.width, height: $0.height, dpi: dpi, raster: $0, profile: profile) })
    }

    /// A multi-page PDF of raster and/or vector pages (shapes stay vectors).
    public static func write(pages: [PDFPageSpec], title: String? = nil) throws -> Data {
        guard !pages.isEmpty else { throw PlatformError.encodeFailed("no pages") }
        let out = NSMutableData()
        guard let consumer = CGDataConsumer(data: out) else { throw PlatformError.frameworkFailure("PDF consumer") }
        var info: [CFString: Any] = [kCGPDFContextCreator: "PhotoCraftNative PCPlatform"]
        if let title { info[kCGPDFContextTitle] = title }
        var first = CGRect(x: 0, y: 0, width: Double(pages[0].width) * 72 / pages[0].dpi, height: Double(pages[0].height) * 72 / pages[0].dpi)
        guard let ctx = CGContext(consumer: consumer, mediaBox: &first, info as CFDictionary) else { throw PlatformError.frameworkFailure("PDF context") }
        for p in pages {
            let s = 72 / p.dpi
            var box = CGRect(x: 0, y: 0, width: Double(p.width) * s, height: Double(p.height) * s)
            let boxData = withUnsafeBytes(of: &box) { Data($0) }
            ctx.beginPDFPage([kCGPDFContextMediaBox: boxData] as CFDictionary)
            if let r = p.raster {
                let img = try SurfaceBridge.cgImage(r.format.sample == .f32 ? r.converted(to: .u16) : r,
                                                    colorSpace: p.profile.flatMap { $0.colorMode?.colorChannels == r.format.mode.colorChannels ? $0.cgColorSpace : nil })
                ctx.draw(img, in: CGRect(x: 0, y: 0, width: Double(r.width) * s, height: Double(r.height) * s).offsetBy(dx: 0, dy: box.height - Double(r.height) * s))
            }
            if !p.shapes.isEmpty {
                ctx.saveGState()
                // Document pixels (y down) → PDF points (y up).
                ctx.concatenate(CGAffineTransform(a: s, b: 0, c: 0, d: -s, tx: 0, ty: box.height))
                for sh in p.shapes { try draw(sh, in: ctx, page: PixelRect(x: 0, y: 0, width: p.width, height: p.height)) }
                ctx.restoreGState()
            }
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return out as Data
    }

    static func solid(_ f: Fill?) -> PCColor? { if case .solid(let c)? = f { return c } else { return nil } }

    /// Draws a shape layer into a PDF context whose CTM maps document pixels: as vectors when its
    /// paints are solid, else rasterised.
    static func draw(_ sh: ShapeLayer, in ctx: CGContext, page: PixelRect) throws {
        let fillOK = sh.fill == nil || solid(sh.fill) != nil
        let strokeOK = sh.stroke.map { solid($0.paint) != nil } ?? true
        guard fillOK, strokeOK, !sh.path.inverted else {
            let r = VectorRasterizer.rasterize(sh, format: .rgba8, clip: page)
            guard let b = VectorRasterizer.bounds(of: sh, clip: page) else { return }
            let img = try SurfaceBridge.cgImage(r, rect: b)
            ctx.saveGState()
            ctx.translateBy(x: CGFloat(b.x0), y: CGFloat(b.y1)); ctx.scaleBy(x: 1, y: -1)
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: b.width, height: b.height))
            ctx.restoreGState()
            return
        }
        func set(_ c: PCColor, _ opacity: Float = 1) {
            let rgb = c.rgb
            ctx.setFillColor(CGColor(srgbRed: CGFloat(rgb.x), green: CGFloat(rgb.y), blue: CGFloat(rgb.z), alpha: CGFloat(c.alpha * opacity)))
        }
        let area = VectorGeometry.fillArea(sh.path)
        if let c = solid(sh.fill) { set(c); ctx.addPath(area); ctx.fillPath(using: .winding) }
        if let st = sh.stroke, st.width > 0, st.opacity > 0, let c = solid(st.paint) {
            var style = StrokeStyle(st)
            let aligned = st.align != .center && sh.path.subpaths.allSatisfy(\.closed)
            if aligned { style.width *= 2 }
            var outline = VectorGeometry.strokeOutline(sh.path, style: style)
            if aligned { outline = st.align == .inside ? outline.intersection(area, using: .winding) : outline.subtracting(area, using: .winding) }
            set(c, min(max(st.opacity, 0), 1)); ctx.addPath(outline); ctx.fillPath(using: .winding)
        }
    }
}
