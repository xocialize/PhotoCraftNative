// Port of photocraft-io (crates/io/src/affinity.rs: `Builder`, `default_name`, `color`), MIT OR
// Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// The layer tree: spreads side by side (Publisher pages as artboards), groups, shapes (with the
// layers they clip), artboards, text, images and masks.

import Foundation
import PCAffinity
import PCDocument
import PCFoundation
import PCIOCore

/// Rust's `f64::max`: NaN yields the other operand.
@inline(__always) func rmax(_ a: Double, _ b: Double) -> Double { Double.maximum(a, b) }
/// Rust's `f64::min`: NaN yields the other operand.
@inline(__always) func rmin(_ a: Double, _ b: Double) -> Double { Double.minimum(a, b) }
/// Rust's `f64::clamp`: NaN passes through.
@inline(__always) func rclamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { v < lo ? lo : (v > hi ? hi : v) }

/// Maps one Affinity document onto a PhotoCraft document.
final class AffinityBuilder {
    var doc: Document
    var warnings: [String] = []
    /// Pixel format of the layers made here (an RGB, 8-bit document).
    let format: PixelFormat = .rgba8
    /// Document pixels (in the canvas) per Affinity document pixel are always 1; spreads are offset.
    let canvas: PixelRect
    let renderer: (any LayerContentRenderer)?
    let codec: any FlatImageCodec

    init(_ name: String, _ d: Affinity.Document, renderer: (any LayerContentRenderer)?, codec: any FlatImageCodec) throws {
        // Spreads (Publisher pages) side by side, 64 px apart.
        var w = 0.0
        var h = 0.0
        for (i, s) in d.spreads.enumerated() {
            w += rmax(s.bounds.x1 - s.bounds.x0, 1) + (i > 0 ? 64 : 0)
            h = rmax(h, rmax(s.bounds.y1 - s.bounds.y0, 1))
        }
        if !(w.isFinite && h.isFinite) || w > AffinityImport.maxSide || h > AffinityImport.maxSide {
            throw PCIOError.unsupported("the Affinity document is larger than 300 000 pixels on a side")
        }
        let width: UInt32 = satCast(rmax(w.rounded(.up), 1))
        let height: UInt32 = satCast(rmax(h.rounded(.up), 1))
        doc = Document(name: name, size: PixelSize(width: Int(width), height: Int(height)), mode: .rgb, depth: .u8)
        doc.resolutionDpi = Float(d.dpi)
        canvas = PixelRect(x0: 0, y0: 0, x1: Int32(clamping: width), y1: Int32(clamping: height))
        self.renderer = renderer
        self.codec = codec
    }

    func warn(_ w: String) {
        if !warnings.contains(w) { warnings.append(w) }
    }

    func document(_ d: Affinity.Document) {
        let pages = d.spreads.count > 1 || d.spreads.contains { $0.pages.count > 1 }
        var x = 0.0
        var layers: [Layer] = []
        for (i, spread) in d.spreads.enumerated() {
            let toDoc = PCAffine.translate(x - spread.bounds.x0, -spread.bounds.y0)
            let children = self.layers(spread.nodes, toDoc)
            if pages {
                // Each page becomes an artboard holding the art drawn on it.
                let rects = spread.pages.isEmpty ? [spread.bounds] : spread.pages
                let page = rects.first ?? spread.bounds
                let r = bbox(toDoc, page)
                let board = Artboard(rect: r, background: .white, preset: "")
                layers.append(Layer(name: "Page \(i + 1)", content: .group(LayerGroup(children: children, expanded: true, artboard: board))))
                if rects.count > 1 {
                    warn("facing pages import as one artboard per spread")
                }
            } else {
                layers += children
            }
            x += rmax(spread.bounds.x1 - spread.bounds.x0, 1) + 64
        }
        if let first = d.spreads.first, !first.transparent, !Self.hasArtboards(layers) {
            // An opaque page: a white background below the art.
            var bg = Surface(format: format, defaultPixel: [1, 1, 1, 1])
            bg.prune()
            var l = Layer(name: "Background", content: .raster(bg))
            l.locks.transparency = true
            l.locks.position = true
            layers.insert(l, at: 0)
        }
        doc.layers = layers
    }

    static func hasArtboards(_ layers: [Layer]) -> Bool {
        layers.contains { $0.group?.artboard != nil }
    }

    /// Integer bounding box of `r` mapped by `m`, clipped to the canvas.
    func bbox(_ m: PCAffine, _ r: Affinity.Rect) -> PixelRect {
        let pts = [(r.x0, r.y0), (r.x1, r.y0), (r.x1, r.y1), (r.x0, r.y1)].map { m.apply(PCPoint($0.0, $0.1)) }
        let x0 = pts.reduce(Double.infinity) { rmin($0, $1.x) }.rounded(.down)
        let y0 = pts.reduce(Double.infinity) { rmin($0, $1.y) }.rounded(.down)
        let x1 = pts.reduce(-Double.infinity) { rmax($0, $1.x) }.rounded(.up)
        let y1 = pts.reduce(-Double.infinity) { rmax($0, $1.y) }.rounded(.up)
        func c(_ v: Double, _ lo: Int32, _ hi: Int32) -> Int32 { satCast(rclamp(v, Double(lo), Double(hi))) }
        return PixelRect(
            x0: c(x0, canvas.x0, canvas.x1),
            y0: c(y0, canvas.y0, canvas.y1),
            x1: c(x1, canvas.x0, canvas.x1),
            y1: c(y1, canvas.y0, canvas.y1)
        )
    }

    func blend(_ b: Affinity.Blend) -> BlendMode {
        switch b {
        case .normal: return .normal
        case .passThrough: return .passThrough
        case .darken: return .darken
        case .darkerColor: return .darkerColor
        case .multiply: return .multiply
        case .colorBurn: return .colorBurn
        case .lighten: return .lighten
        case .lighterColor: return .lighterColor
        case .screen: return .screen
        case .colorDodge: return .colorDodge
        case .add: return .linearDodge
        case .overlay: return .overlay
        case .softLight: return .softLight
        case .hardLight: return .hardLight
        case .vividLight: return .vividLight
        case .pinLight: return .pinLight
        case .linearLight: return .linearLight
        case .hardMix: return .hardMix
        case .difference: return .difference
        case .exclusion: return .exclusion
        case .subtract: return .subtract
        case .hue: return .hue
        case .saturation: return .saturation
        case .luminosity: return .luminosity
        case .color: return .color
        case .average, .negation, .reflect, .glow, .erase:
            warn("the Average, Negation, Reflect, Glow and Erase blend modes import as Normal")
            return .normal
        }
    }

    func base(_ n: Affinity.Node, _ content: LayerContent) -> Layer {
        var l = Layer(name: n.name.isEmpty ? Self.defaultName(n.kind) : n.name, content: content)
        l.visible = n.visible
        l.opacity = Float(n.opacity)
        l.blend = blend(n.blend)
        if n.locked {
            l.locks = Locks(all: true)
        }
        return l
    }

    func group(_ n: Affinity.Node, _ children: [Layer]) -> Layer {
        // Pass-through and Normal (isolated) groups map one to one.
        base(n, .group(LayerGroup(children: children, expanded: false, artboard: nil)))
    }

    /// The layers of `roots` (a spread's nodes) and their subtrees; `toDoc` maps Affinity document
    /// pixels to the canvas. photocraft's `layer` recursion (children first, then the node, in
    /// order) on an explicit stack: PCAffinity returns trees 128 levels deep, and a recursive walk
    /// over `Layer` values needs megabytes of stack in a debug build.
    func layers(_ roots: [Affinity.Node], _ toDoc: PCAffine) -> [Layer] {
        struct Pending {
            /// nil for the spread, which only collects its children.
            var node: Affinity.Node?
            var next = 0
            var out: [Layer] = []
        }
        var stack = [Pending(node: nil)]
        while var top = stack.popLast() {
            let children = top.node?.children ?? roots
            if top.next < children.count {
                let c = children[top.next]
                top.next += 1
                stack.append(top)
                stack.append(Pending(node: c))
                continue
            }
            guard let n = top.node else { return top.out }
            // A node whose parent is the spread is a top-level layer.
            let isTop = stack.last?.node == nil
            if let l = layer(n, top.out, toDoc, top: isTop), !stack.isEmpty {
                stack[stack.count - 1].out.append(l)
            }
        }
        return []
    }

    /// One Affinity node, its children already mapped.
    func layer(_ n: Affinity.Node, _ children: [Layer], _ toDoc: PCAffine, top: Bool) -> Layer? {
        var l: Layer
        switch n.kind {
        case .layer, .group:
            l = group(n, children)
        case .unsupported:
            if children.isEmpty { return nil }
            l = group(n, children)
        case .shape(let outline, let fills, let strokes, let evenOdd):
            let path = self.path(outline, toDoc, evenOdd)
            let shape = self.shape(path, fills, strokes, toDoc)
            if children.isEmpty {
                l = base(n, .shape(shape))
            } else {
                // A shape clips its children: a group masked by the outline, the shape at its bottom.
                var own = Layer(name: n.name.isEmpty ? "Shape" : n.name, content: .shape(shape))
                own.opacity = 1
                var g = group(n, [own] + children)
                g.vectorMask = VectorMask(path: path, enabled: true, linked: true, density: 1, feather: 0)
                if !strokes.isEmpty {
                    warn("strokes of shapes that clip other layers are clipped to the shape")
                }
                l = g
            }
        case .artboard(let rect, let background):
            let r = bbox(toDoc, rect)
            let bg: ArtboardBackground
            switch background.first {
            case .solid(let c)?:
                let c = Self.color(c)
                bg = c.alpha <= 0 ? .transparent : .custom(c)
            case .some:
                warn("artboard backgrounds other than a solid colour import as transparent")
                bg = .transparent
            case nil:
                bg = .transparent
            }
            var g = group(n, children)
            if top {
                g.withGroup { $0.artboard = Artboard(rect: r, background: bg, preset: "") }
            } else {
                // PhotoCraft artboards are top-level groups: a nested one clips by a vector mask.
                let p = VectorPath([Subpath.polygon([
                    (Double(r.x0), Double(r.y0)),
                    (Double(r.x1), Double(r.y0)),
                    (Double(r.x1), Double(r.y1)),
                    (Double(r.x0), Double(r.y1)),
                ])])
                g.vectorMask = VectorMask(path: p, enabled: true, linked: true, density: 1, feather: 0)
                warn("artboards inside groups import as masked groups")
            }
            l = g
        case .text(let t):
            let layer = text(t, toDoc)
            let tl = base(n, .text(layer))
            l = children.isEmpty ? tl : group(n, [tl] + children)
        case .image(let img):
            if let content = image(img, toDoc) {
                l = base(n, content)
            } else if children.isEmpty {
                return nil
            } else {
                l = group(n, children)
            }
        }
        if let mask = n.mask {
            l.vectorMask = VectorMask(path: path(mask, toDoc, false), enabled: true, linked: true, density: 1, feather: 0)
        }
        if let mask = n.pixelMask, let surface = self.mask(mask, toDoc) {
            l.mask = LayerMask(surface: surface, enabled: true, linked: true, density: 1, feather: 0)
        }
        return l
    }

    func path(_ p: Affinity.Path, _ m: PCAffine, _ evenOdd: Bool) -> VectorPath {
        let subpaths = p.subpaths.map { s -> Subpath in
            // Knots: each anchor with the control points of the segments arriving and leaving.
            var knots: [Knot] = []
            knots.reserveCapacity(s.segments.count + 1)
            let start = m.apply(Self.point(s.start))
            knots.append(.corner(start.x, start.y))
            for seg in s.segments {
                knots[knots.count - 1].outCtrl = m.apply(Self.point(seg.c1))
                let e = m.apply(Self.point(seg.end))
                var k = Knot.corner(e.x, e.y)
                k.inCtrl = m.apply(Self.point(seg.c2))
                knots.append(k)
            }
            // A closed subpath that ends where it starts: the last knot is the first.
            if s.closed, knots.count > 1, let f = knots.first, let l = knots.last,
               abs(f.anchor.x - l.anchor.x) < 1e-9, abs(f.anchor.y - l.anchor.y) < 1e-9 {
                knots.removeLast()
                knots[0].inCtrl = l.inCtrl
            }
            return Subpath(closed: s.closed, knots: knots, op: .combine)
        }
        var path = VectorPath(subpaths)
        if evenOdd {
            // One component filled even-odd, so inner subpaths cut holes as in Affinity.
            path.fillRule = .evenOdd
            for i in path.subpaths.indices.dropFirst() {
                path.subpaths[i].op = .join
            }
        }
        return path
    }

    func fill(_ p: Affinity.Paint, _ frame: PixelRect, _ toDoc: PCAffine) -> Fill? {
        switch p {
        case .none:
            return nil
        case .solid(let c):
            return .solid(Self.color(c))
        case .gradient(let g):
            let style: GradientStyle
            switch g.kind {
            case .linear: style = .linear
            case .radial: style = .radial
            case .conical: style = .angle
            }
            let m = toDoc.mul(Self.affine(g.transform))
            let o = m.apply(PCPoint(0, 0)), e = m.apply(PCPoint(1, 0)), v = m.apply(PCPoint(0, 1))
            let u = hypot(e.x - o.x, e.y - o.y), w = hypot(v.x - o.x, v.y - o.y)
            if style == .radial && u > 0 && abs(w / u - 1) > 0.01 {
                warn("elliptical gradients import as circular ones")
            }
            let (angle, scale, offset) = GradientHandles.fromHandles(
                style, SIMD2(Float(o.x), Float(o.y)), SIMD2(Float(e.x), Float(e.y)), frame, 0)
            let stops = g.stops.map { s -> ColorStop in
                var c = Self.color(s.color)
                c.alpha = 1
                return ColorStop(Float(s.offset), c)
            }
            let opacityStops = g.stops.map { OpacityStop(Float($0.offset), Float($0.color.alpha)) }
            let midpoints = g.stops.dropLast().map { Float($0.halfPoint) }
            return .gradient(GradientFill(stops: stops, angle: angle, scale: scale, style: style, reverse: false, opacityStops: opacityStops,
                                          midpoints: midpoints, offset: offset, dither: false, align: true))
        }
    }

    func shape(_ path: VectorPath, _ fills: [Affinity.Paint], _ strokes: [Affinity.Stroke], _ toDoc: PCAffine) -> ShapeLayer {
        let frame = path.controlBounds.map { b in
            PixelRect(x0: satCast(b.x.rounded(.down)), y0: satCast(b.y.rounded(.down)), x1: satCast(b.z.rounded(.up)), y1: satCast(b.w.rounded(.up)))
        } ?? canvas
        if fills.count > 1 || strokes.count > 1 {
            warn("only one fill and one stroke per shape import")
        }
        let fill = fills.first.flatMap { self.fill($0, frame, toDoc) }
        var stroke: ShapeStroke?
        if let s = strokes.first, let paint = self.fill(s.paint, frame, toDoc) {
            if s.behind {
                warn("strokes drawn behind their fill import in front of it")
            }
            let align: StrokeAlign
            switch s.align {
            case .center: align = .center
            case .inside: align = .inside
            case .outside: align = .outside
            }
            let cap: LineCap
            switch s.cap {
            case .butt: cap = .butt
            case .round: cap = .round
            case .square: cap = .square
            }
            let join: LineJoin
            switch s.join {
            case .miter: join = .miter
            case .round: join = .round
            case .bevel: join = .bevel
            }
            // In multiples of the width, as Photoshop stores them.
            let unit = rmax(s.width, 1e-9)
            stroke = ShapeStroke(width: Float(s.width), paint: paint, opacity: 1, align: align, cap: cap, join: join,
                                 miterLimit: Float(s.miterLimit),
                                 dashes: s.dash.map { $0.lengths.map { Float($0 / unit) } } ?? [],
                                 dashOffset: s.dash.map { Float($0.phase / unit) } ?? 0)
        }
        var sh = ShapeLayer(path: path, fill: fill, stroke: stroke, live: nil, cache: nil, psdRaw: nil)
        sh.cache = renderer?.renderShape(sh, format: format, canvas: canvas)
        return sh
    }

    func text(_ t: Affinity.Text, _ toDoc: PCAffine) -> TextLayer {
        let origin = t.frame.map { PCPoint($0.x0, $0.y0) } ?? Self.point(t.anchor)
        let m = toDoc.mul(Self.affine(t.transform)).mul(.translate(origin.x, origin.y))
        let k = rmax(abs(m.determinant).squareRoot(), 1e-9)
        let transform = m.mul(.scale(1 / k))
        let dpi = Double(Float.maximum(doc.resolutionDpi, 1))
        var text = ""
        var runs: [TextRun] = []
        for r in t.runs {
            // Affinity separates paragraphs with U+2029 and lines with U+2028.
            var scalars = String.UnicodeScalarView()
            scalars.append(contentsOf: r.text.unicodeScalars.map { $0 == "\u{2029}" || $0 == "\u{2028}" ? "\r" : $0 })
            let s = String(scalars)
            var style = CharStyle()
            style.fontFamily = r.family
            style.postscriptName = r.postscript.isEmpty ? nil : r.postscript
            style.weight = UInt16(min(max(r.weight, 100), 900))
            style.italic = r.italic
            style.sizePt = Float(r.size * k * 72 / dpi)
            if case .solid(let c) = r.fill {
                style.color = Self.color(c)
            } else {
                style.color = .black
            }
            style.tracking = Float(r.tracking * 1000)
            style.leadingPt = r.leading.map { Float($0 * k * 72 / dpi) }
            text += s
            runs.append(TextRun(len: s.utf8.count, style: style))
        }
        let align: TextAlign
        switch t.align {
        case .left: align = .left
        case .center: align = .center
        case .right: align = .right
        case .justify: align = .justifyLeft
        }
        var layer = TextLayer(text: text, fontFamily: runs.first?.style.fontFamily ?? "", sizePt: runs.first?.style.sizePt ?? 12,
                              color: runs.first?.style.color ?? .black)
        layer.transform = transform
        layer.runs = runs
        layer.paragraphs = [ParagraphRun(len: text.utf8.count, style: ParagraphStyle(align: align))]
        if let f = t.frame {
            layer.shape = .box(TextShape.TextBox(x: 0, y: 0, width: Float((f.x1 - f.x0) * k), height: Float((f.y1 - f.y0) * k)))
        }
        // Type layers draw from their model, within the import's raster bound.
        if let renderer {
            AffinityImport.prepareText(&layer, renderer, dpi: doc.resolutionDpi, format: doc.pixelFormat)
        }
        return layer
    }

    // MARK: - Small conversions

    static func affine(_ a: Affinity.Affine) -> PCAffine {
        PCAffine(a: a.a, b: a.b, c: a.c, d: a.d, e: a.e, f: a.f)
    }

    static func point(_ p: Affinity.Point) -> PCPoint {
        PCPoint(p.x, p.y)
    }

    static func defaultName(_ k: Affinity.Node.Kind) -> String {
        switch k {
        case .layer: "Layer"
        case .group: "Group"
        case .artboard: "Artboard"
        case .shape: "Shape"
        case .text: "Text"
        case .image: "Image"
        case .unsupported: "Group"
        }
    }

    /// An Affinity colour as straight sRGB (CMYK and Lab through PhotoCraft's conversions).
    static func color(_ c: Affinity.Color) -> PCColor {
        func f(_ v: Double) -> Float { Float(rclamp(v, 0, 1)) }
        switch c {
        case .rgb(let r, let g, let b, let a):
            return .rgb(f(r), f(g), f(b), f(a))
        case .cmyk(let c, let m, let y, let k, let a):
            let rgb = PCColor(mode: .cmyk, c: SIMD4(f(c), f(m), f(y), f(k)), alpha: f(a)).rgb
            return .rgb(rgb.x, rgb.y, rgb.z, f(a))
        case .gray(let v, let a):
            return .rgb(f(v), f(v), f(v), f(a))
        case .lab(let l, let a, let b, let alpha):
            let rgb = PCColor(mode: .lab, c: SIMD4(f(l / 100), f((a + 128) / 255), f((b + 128) / 255), 0), alpha: f(alpha)).rgb
            return .rgb(rgb.x, rgb.y, rgb.z, f(alpha))
        }
    }
}
