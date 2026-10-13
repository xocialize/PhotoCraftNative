// Rasterising for the SVG import, natively. photocraft-io (crates/io/src/svg.rs) renders shape
// caches with photocraft-vector and everything the shape model cannot hold with resvg; here:
//
// * shape caches are drawn with CoreGraphics from the converted path, with the SVG paint's exact
//   geometry (a gradient's real direction and extent, which the layer's gradient fill only
//   approximates);
// * clip paths, masks, filters, patterns, markers, images, nested viewports and whole drawings
//   are rendered by CoreSVG through `NSImage(data:)`, fed a standalone SVG serialised from the
//   resolved tree (styles folded into attributes, `use` expanded, only `data:` image references
//   kept: CoreSVG would otherwise read `file:` and relative hrefs from disk).
//
// MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import AppKit
import CoreGraphics
import Foundation
import PCDocument
import PCFoundation
import PCIOCore

extension SVGImport {
    /// A straight-alpha RGBA8 buffer over `rect` (canvas pixels).
    struct Bitmap {
        var rect: PixelRect
        var rgba: [UInt8]

        /// The pixels as a surface in `fmt` covering `rect`.
        func surface(_ fmt: PixelFormat) -> Surface {
            var s = Surface(format: fmt)
            write(into: &s)
            s.prune()
            return s
        }

        /// Writes the pixels into `s` at `rect`.
        func write(into s: inout Surface) {
            guard !rect.isEmpty else { return }
            if s.format == .rgba8 {
                s.writeInterleaved(rect, rgba)
            } else {
                var vals: [Float] = []
                vals.reserveCapacity(rect.area * s.format.channels)
                for i in 0 ..< rect.area {
                    let p = SIMD4(Float(rgba[i * 4]), Float(rgba[i * 4 + 1]), Float(rgba[i * 4 + 2]), Float(rgba[i * 4 + 3])) / 255
                    vals += s.format.components(fromRGBA: p)
                }
                s.writeRegion(rect, vals)
            }
        }

        var isEmpty: Bool { !stride(from: 3, to: rgba.count, by: 4).contains { rgba[$0] != 0 } }
    }

    /// Draws into a transparent sRGB RGBA8 context of `rect`'s size whose user space is canvas
    /// pixels (y down); returns the straight-alpha pixels. `nil` past `maxRasterPixels`.
    static func draw(_ rect: PixelRect, _ body: (CGContext) -> Void) -> Bitmap? {
        let w = rect.width, h = rect.height
        guard w > 0, h > 0, UInt64(w) * UInt64(h) <= maxRasterPixels, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let ok = buf.withUnsafeMutableBytes { p -> Bool in
            guard let ctx = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: 1, y: -1)
            ctx.translateBy(x: CGFloat(-Int(rect.x0)), y: CGFloat(-Int(rect.y0)))
            body(ctx)
            return true
        }
        guard ok else { return nil }
        unpremultiply(&buf)
        return Bitmap(rect: rect, rgba: buf)
    }

    static func unpremultiply(_ buf: inout [UInt8]) {
        var i = 0
        while i + 3 < buf.count {
            let a = Int(buf[i + 3])
            if a > 0, a < 255 {
                for c in 0 ..< 3 { buf[i + c] = UInt8(min(255, (Int(buf[i + c]) * 255 + a / 2) / a)) }
            } else if a == 0 {
                buf[i] = 0; buf[i + 1] = 0; buf[i + 2] = 0
            }
            i += 4
        }
    }

    /// The integer pixel rectangle covering `r`, clipped to `canvas`.
    static func pixelRect(_ r: CGRect, _ canvas: PixelRect) -> PixelRect {
        guard !r.isNull, !r.isInfinite, r.minX.isFinite, r.maxX.isFinite, r.minY.isFinite, r.maxY.isFinite else { return .empty }
        let x0: Int32 = satCast(r.minX.rounded(.down)), y0: Int32 = satCast(r.minY.rounded(.down))
        let x1: Int32 = satCast(r.maxX.rounded(.up)), y1: Int32 = satCast(r.maxY.rounded(.up))
        return PixelRect(x0: x0, y0: y0, x1: x1, y1: y1).intersect(canvas)
    }

    // MARK: - Shape caches (CoreGraphics)

    /// A stroke as drawn: the shape model's averaged width and dash pattern in pixels.
    struct StrokeDraw {
        var paint: Paint
        var opacity: Double
        var width: Double
        var cap: CGLineCap
        var join: CGLineJoin
        var miterLimit: Double
        var dashes: [Double]
        var dashOffset: Double
    }

    /// Renders a converted shape: `path` in canvas pixels, paints whose gradient geometry maps to
    /// the canvas through `paintToCanvas` (the element's user space → canvas).
    static func renderShape(path: CGPath, evenOdd: Bool, fill: (Paint, Double)?, stroke: StrokeDraw?, paintToCanvas: CGAffineTransform,
                            canvas: PixelRect, format: PixelFormat) -> Surface {
        var surface = Surface(format: format)
        var bounds = path.boundingBoxOfPath
        if let s = stroke, s.width > 0 {
            let stroked = path.copy(strokingWithWidth: s.width, lineCap: s.cap, lineJoin: s.join, miterLimit: s.miterLimit)
            bounds = bounds.union(stroked.boundingBoxOfPath)
        }
        let rect = pixelRect(bounds.insetBy(dx: -1, dy: -1), canvas)
        guard !rect.isEmpty else { return surface }
        // In bands of at most 4 M pixels: a shape may cover the whole 16384² canvas.
        let rows = max(1, min(rect.height, (4 << 20) / max(1, rect.width)))
        var y = Int(rect.y0)
        while y < Int(rect.y1) {
            let band = PixelRect(x0: rect.x0, y0: Int32(y), x1: rect.x1, y1: Int32(min(Int(rect.y1), y + rows)))
            let bm = draw(band) { ctx in
                if let (paint, opacity) = fill {
                    ctx.saveGState()
                    ctx.addPath(path)
                    fillCurrentPath(ctx, paint, opacity: opacity, evenOdd: evenOdd, paintToCanvas: paintToCanvas)
                    ctx.restoreGState()
                }
                if let s = stroke, s.width > 0 {
                    ctx.saveGState()
                    ctx.addPath(path)
                    ctx.setLineWidth(s.width)
                    ctx.setLineCap(s.cap)
                    ctx.setLineJoin(s.join)
                    ctx.setMiterLimit(s.miterLimit)
                    if !s.dashes.isEmpty { ctx.setLineDash(phase: s.dashOffset, lengths: s.dashes.map { CGFloat($0) }) }
                    ctx.replacePathWithStrokedPath()
                    fillCurrentPath(ctx, s.paint, opacity: s.opacity, evenOdd: false, paintToCanvas: paintToCanvas)
                    ctx.restoreGState()
                }
            }
            if let bm, !bm.isEmpty { bm.write(into: &surface) }
            y = Int(band.y1)
        }
        surface.prune()
        return surface
    }

    /// Fills the context's current path with a solid colour or a gradient.
    static func fillCurrentPath(_ ctx: CGContext, _ paint: Paint, opacity: Double, evenOdd: Bool, paintToCanvas: CGAffineTransform) {
        switch paint {
        case let .color(c):
            ctx.setFillColor(CGColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a * opacity))
            ctx.fillPath(using: evenOdd ? .evenOdd : .winding)
        case let .gradient(g):
            ctx.clip(using: evenOdd ? .evenOdd : .winding)
            guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return }
            let colors = g.stops.map { CGColor(srgbRed: $0.color.r, green: $0.color.g, blue: $0.color.b, alpha: $0.color.a * opacity) }
            let locations = g.stops.map { CGFloat($0.offset) }
            guard let cg = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations) else { return }
            ctx.concatenate(then(g.transform, paintToCanvas))
            let opts: CGGradientDrawingOptions = [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            if g.radial {
                ctx.drawRadialGradient(cg, startCenter: CGPoint(x: g.fx, y: g.fy), startRadius: 0, endCenter: CGPoint(x: g.cx, y: g.cy),
                                       endRadius: g.r, options: opts)
            } else {
                ctx.drawLinearGradient(cg, start: CGPoint(x: g.x1, y: g.y1), end: CGPoint(x: g.x2, y: g.y2), options: opts)
            }
        case .pattern:
            break // pattern paints are rasterised with CoreSVG before this
        }
    }

    // MARK: - CoreSVG

    /// CoreSVG is not documented as thread-safe: one render at a time.
    static let coreSVGLock = NSLock()

    /// Renders a standalone SVG document of `w × h` px (its own size) with CoreSVG; straight
    /// alpha. `nil` when `NSImage` cannot read it.
    static func renderCoreSVG(_ xml: String, _ rect: PixelRect) -> Bitmap? {
        let w = rect.width, h = rect.height
        guard w > 0, h > 0, UInt64(w) * UInt64(h) <= maxRasterPixels, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return coreSVGLock.withLock { () -> Bitmap? in
            guard let image = NSImage(data: Data(xml.utf8)) else { return nil }
            var buf = [UInt8](repeating: 0, count: w * h * 4)
            let ok = buf.withUnsafeMutableBytes { p -> Bool in
                guard let ctx = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                let g = NSGraphicsContext(cgContext: ctx, flipped: false)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = g
                image.draw(in: NSRect(x: 0, y: 0, width: w, height: h), from: .zero, operation: .copy, fraction: 1)
                NSGraphicsContext.restoreGraphicsState()
                return true
            }
            guard ok else { return nil }
            unpremultiply(&buf)
            return Bitmap(rect: rect, rgba: buf)
        }
    }

    // MARK: - Serialising

    /// Elements that only exist to be referenced.
    static let resourceElements: Set<String> = [
        "linearGradient", "radialGradient", "pattern", "clipPath", "mask", "filter", "marker", "symbol",
    ]

    /// Properties holding `url(#…)` references.
    static let referenceProperties = ["fill", "stroke", "clip-path", "mask", "filter", "marker", "marker-start", "marker-mid", "marker-end"]

    static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        for c in s.unicodeScalars {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default:
                // Characters XML 1.0 cannot carry are dropped.
                if c.value < 0x20, c != "\t", c != "\n", c != "\r" { continue }
                out.unicodeScalars.append(c)
            }
        }
        return out
    }

    /// A standalone SVG of `rect` (canvas pixels) drawing `nodes` under the user → canvas
    /// transform `ts`, with `inherited` (the computed inheritable properties of their parent) on
    /// a wrapping group and every resource they reference in `<defs>`.
    static func standalone(_ nodes: [Node], ts: CGAffineTransform, inherited: [String: String], rect: PixelRect,
                           ids: [String: Node], viewport: CGSize) -> String {
        var inside = Set<ObjectIdentifier>()
        var stack = nodes
        while let n = stack.popLast() {
            inside.insert(ObjectIdentifier(n))
            stack += n.children
        }
        // Resources referenced from the nodes, transitively.
        var defs: [Node] = []
        var seen = Set<ObjectIdentifier>()
        var queue = nodes
        while let n = queue.popLast() {
            var refs: [String] = []
            for k in referenceProperties { if let v = n.props[k], let id = reference(v) { refs.append(id) } }
            if let h = n.attrs["href"], let id = reference(h) { refs.append(id) }
            for id in refs {
                guard let r = ids[id], !seen.contains(ObjectIdentifier(r)) else { continue }
                seen.insert(ObjectIdentifier(r))
                if !inside.contains(ObjectIdentifier(r)) { defs.append(r) }
                queue.append(r)
            }
            queue += n.children
        }
        var out = "<svg xmlns=\"\(svgNamespace)\" xmlns:xlink=\"http://www.w3.org/1999/xlink\" width=\"\(rect.width)\" height=\"\(rect.height)\" viewBox=\"0 0 \(rect.width) \(rect.height)\">"
        if !defs.isEmpty {
            out += "<defs>"
            for d in defs { serialize(d, &out, viewport: viewport) }
            out += "</defs>"
        }
        // User space → the crop of the canvas.
        let full = ts.concatenating(CGAffineTransform(translationX: CGFloat(-Int(rect.x0)), y: CGFloat(-Int(rect.y0))))
        out += "<g transform=\"matrix(\(full.a) \(full.b) \(full.c) \(full.d) \(full.tx) \(full.ty))\""
        for (k, v) in inherited.sorted(by: { $0.key < $1.key }) where k != "xml:space" { out += " \(k)=\"\(escape(v))\"" }
        out += ">"
        for n in nodes { serialize(n, &out, viewport: viewport) }
        out += "</g></svg>"
        return out
    }

    /// Which viewport side a `%` length of an attribute refers to (0 width, 1 height, 2 diagonal).
    static let percentAxes: [String: Int] = [
        "x": 0, "y": 1, "width": 0, "height": 1, "cx": 0, "cy": 1, "r": 2, "rx": 0, "ry": 1, "x1": 0, "y1": 1, "x2": 0, "y2": 1,
        "dx": 0, "dy": 1, "fx": 0, "fy": 1, "stroke-width": 2, "stroke-dashoffset": 2, "stroke-dasharray": 2,
    ]

    /// Elements whose geometry is in user space (gradients, patterns, masks and filters only with
    /// `userSpaceOnUse` units).
    static func userSpaceLengths(_ n: Node) -> Bool {
        switch n.name {
        case "linearGradient", "radialGradient": n.attrs["gradientUnits"] == "userSpaceOnUse"
        case "pattern": n.attrs["patternUnits"] == "userSpaceOnUse"
        case "mask": n.attrs["maskUnits"] == "userSpaceOnUse"
        case "filter": n.attrs["filterUnits"] == "userSpaceOnUse"
        default: true
        }
    }

    /// `value` with its `%` lengths made absolute: the standalone document's viewport is the crop,
    /// not the drawing's, and CoreSVG clips nested viewports, so `%` cannot be left to it.
    static func absolutePercent(_ value: String, _ axis: Int, _ viewport: CGSize) -> String {
        guard value.contains("%") else { return value }
        let base = axis == 0 ? viewport.width : axis == 1 ? viewport.height
            : ((viewport.width * viewport.width + viewport.height * viewport.height) / 2).squareRoot()
        return value.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map { item -> String in
            guard item.hasSuffix("%"), let v = Double(item.dropLast()) else { return String(item) }
            return "\(v / 100 * base)"
        }.joined(separator: " ")
    }

    /// One element and its subtree with its specified properties as attributes.
    static func serialize(_ n: Node, _ out: inout String, viewport: CGSize) {
        if n.isText {
            out += escape(n.text)
            return
        }
        if n.name.hasPrefix(TreeBuilder.foreign) || ["style", "script", "foreignObject", "use"].contains(n.name) { return }
        // Attribute-less groups are left out: CoreSVG refuses nesting past about 256 levels.
        if n.isTrivialGroup {
            for c in n.children { serialize(c, &out, viewport: viewport) }
            return
        }
        // An image CoreSVG cannot load draws a red placeholder: only decodable data URLs go out.
        if n.name == "image", imageData(n) == nil { return }
        out += "<\(n.name)"
        var attrs = n.attrs
        attrs["style"] = nil
        attrs["class"] = nil
        attrs["pc:symbol"] = nil
        if n.fromUse {
            let x = length(attrs["x"], percentBase: viewport.width) ?? 0
            let y = length(attrs["y"], percentBase: viewport.height) ?? 0
            attrs["x"] = nil
            attrs["y"] = nil
            attrs["transform"] = (attrs["transform"] ?? "") + " translate(\(x) \(y))"
        }
        if let h = attrs["href"] {
            attrs["href"] = nil
            // Only in-document references and data URLs: CoreSVG would read files.
            let t = h.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.hasPrefix("#") || t.lowercased().hasPrefix("data:") { attrs["xlink:href"] = t }
        }
        let user = userSpaceLengths(n)
        for (k, v) in attrs.sorted(by: { $0.key < $1.key }) {
            guard !k.contains(":") || k == "xlink:href" || k == "xml:space" else { continue }
            let value = user ? percentAxes[k].map { absolutePercent(v, $0, viewport) } ?? v : v
            out += " \(k)=\"\(escape(value))\""
        }
        for (k, v) in n.props.sorted(by: { $0.key < $1.key }) where k != "font" {
            out += " \(k)=\"\(escape(percentAxes[k].map { absolutePercent(v, $0, viewport) } ?? v))\""
        }
        if n.children.isEmpty {
            out += "/>"
            return
        }
        out += ">"
        // A nested viewport sets the `%` base of its content.
        var inner = viewport
        if n.name == "svg" {
            if let vb = viewBox(n.attrs["viewBox"]) {
                inner = vb.size
            } else {
                inner = CGSize(width: length(n.attrs["width"] ?? "100%", percentBase: viewport.width) ?? viewport.width,
                               height: length(n.attrs["height"] ?? "100%", percentBase: viewport.height) ?? viewport.height)
            }
        }
        for c in n.children { serialize(c, &out, viewport: inner) }
        out += "</\(n.name)>"
    }
}
