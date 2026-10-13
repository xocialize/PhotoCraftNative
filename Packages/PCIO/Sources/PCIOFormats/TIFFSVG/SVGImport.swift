// Port of photocraft-io (crates/io/src/svg.rs), MIT OR Apache-2.0, © ArtCraft Team and the
// PhotoCraft contributors.
//
// SVG import: a drawing opens as a document of shape layers, and places as a vector smart object
// that is re-rasterised at its placement scale (`rasterize`).
//
// photocraft parses with usvg (CSS, `use`, units, nested transforms, text as outlines) and
// rasterises with resvg. Natively: Foundation's `XMLParser` builds the tree (SVGDocument.swift:
// presentation attributes, `style` and simple `<style>` CSS, inheritance, `use`/`symbol`), each
// path or basic shape becomes a `ShapeLayer` (cubic Bézier knots, fill, stroke; SVGGeometry.swift)
// whose cache CoreGraphics draws, each group a layer group with its opacity and blend mode, and
// text becomes outline shapes through CoreText (SVGText.swift). What the shape model cannot hold —
// clip paths, masks, filters, pattern paints, markers, clipped viewports (`symbol`, nested `svg`),
// embedded images, text on a path — is rendered by CoreSVG (`NSImage(data:)`) into a pixel layer
// so the picture still looks right, with a warning (SVGRender.swift); gradient paints keep their
// stops and direction in the layer's own gradient fill, with a warning that the exact geometry is
// not kept.

import CoreGraphics
import Foundation
import ImageIO
import PCDocument
import PCFoundation
import PCIOCore

/// SVG and SVGZ import (photocraft `svg`).
public enum SVGImport {
    /// Largest canvas side an SVG opens at; a larger drawing is scaled down to fit.
    public static let maxSide: UInt32 = 16_384
    /// A rasterised fallback layer or a smart-object render never exceeds this many pixels.
    static let maxRasterPixels: UInt64 = 24_000_000
    /// Past this many drawable elements the whole drawing opens as one pixel layer.
    static let maxNodes = 2_000
    /// Nesting past which a subtree is rasterised instead of walked (bounded recursion).
    static let maxRecursion = 200
    /// Deepest element nesting accepted (checked on the markup before parsing).
    public static let maxXMLDepth = 512
    /// Largest `.svgz` accepted once inflated (a 1.5 MB gzip can hold 1.5 GB of whitespace).
    public static let maxInflatedBytes: UInt64 = 128 << 20

    /// Does this look like an SVG document (plain XML; `.svgz` is recognised by its extension)?
    public static func isSVG(_ bytes: [UInt8]) -> Bool {
        let head = String(decoding: bytes.prefix(4096), as: UTF8.self)
        let t = head.drop { $0 == "\u{FEFF}" || $0.isWhitespace }
        if t.hasPrefix("<svg") { return true }
        return (t.hasPrefix("<?xml") || t.hasPrefix("<!DOCTYPE") || t.hasPrefix("<!--")) && t.contains("<svg")
    }

    /// Opens an SVG (or SVGZ) as a document of shape layers, rasterising any subtree nested
    /// deeper than `maxGroupDepth` groups into a pixel layer (0 disables the setting; the
    /// document's hard limit, `maxGroupDepthLimit`, always applies).
    public static func importDocument(name: String, bytes: [UInt8], maxGroupDepth: Int = maxGroupDepthLimit) throws -> ImportResult {
        try onLargeStack {
            let parsed = try parse(bytes)
            return importParsed(name, parsed, maxGroupDepth)
        }
    }

    /// The result of work done on another thread.
    final class ResultBox<T>: @unchecked Sendable {
        var result: Result<T, any Error>?
    }

    /// Runs `body` on a thread with a 64 MB stack and waits for it. The tree walks recurse once
    /// per element level (up to `maxXMLDepth`), which a 512 KB worker stack does not hold in
    /// unoptimised builds.
    static func onLargeStack<T: Sendable>(_ body: @escaping @Sendable () throws -> T) throws -> T {
        let box = ResultBox<T>()
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            box.result = Result { try body() }
            done.signal()
        }
        thread.stackSize = 64 << 20
        thread.start()
        done.wait()
        guard let r = box.result else { throw PCIOError.format("SVG", "the import thread did not finish") }
        return try r.get()
    }

    /// The whole drawing rendered at `scale` (1 = its own size), straight-alpha sRGB, row-major
    /// from the top-left. Smart objects use it to stay sharp at any placement.
    public struct Raster: Sendable {
        public var width: Int
        public var height: Int
        public var pixels: [SIMD4<Float>]
    }

    /// Renders the whole drawing at `scale` (clamped to 1/64...64).
    public static func rasterize(_ bytes: [UInt8], _ scale: Float) throws -> Raster {
        try onLargeStack { try rasterizeParsed(try parse(bytes), scale) }
    }

    static func rasterizeParsed(_ p: Parsed, _ scale: Float) throws -> Raster {
        var w0: [String] = []
        let cv = canvas(p.size, &w0)
        let k = cv.scale * Double(min(max(scale.isFinite ? scale : 1, 1.0 / 64), 64))
        let side = { (v: Double) -> Int in
            let x = (v * k).rounded(.up)
            return x.isFinite ? Int(min(max(x, 1), 1e9)) : 1
        }
        let (w, h) = (side(p.size.width), side(p.size.height))
        guard UInt64(w) * UInt64(h) <= maxRasterPixels else { throw PCIOError.format("SVG", "\(w) × \(h) px is too large to rasterise") }
        let rect = PixelRect(x0: 0, y0: 0, x1: Int32(w), y1: Int32(h))
        let ts = then(p.rootTransform, CGAffineTransform(scaleX: k, y: k))
        let xml = standalone(p.root.children, ts: ts, inherited: inheritable(computedStyle([:], p.root)), rect: rect, ids: p.ids, viewport: p.viewport)
        guard let bm = renderCoreSVG(xml, rect) else { throw PCIOError.format("SVG", "the drawing could not be rendered") }
        var px: [SIMD4<Float>] = []
        px.reserveCapacity(w * h)
        for i in 0 ..< w * h {
            px.append(SIMD4(Float(bm.rgba[i * 4]), Float(bm.rgba[i * 4 + 1]), Float(bm.rgba[i * 4 + 2]), Float(bm.rgba[i * 4 + 3])) / 255)
        }
        return Raster(width: w, height: h, pixels: px)
    }

    // MARK: - Parsing

    /// A parsed drawing.
    struct Parsed {
        var root: Node
        var ids: [String: Node]
        /// The drawing's size in px (`width` × `height`, or the `viewBox`).
        var size: CGSize
        /// The root `viewBox` → px mapping.
        var rootTransform: CGAffineTransform
        /// The size `%` lengths refer to at the root (the `viewBox`, else the size).
        var viewport: CGSize
        var warnings: [String]
    }

    /// Parses a drawing, `.svgz` included. The XML is inflated and checked here, before the
    /// parser sees it: deeper nesting than `maxXMLDepth` is an error.
    static func parse(_ bytes: [UInt8]) throws -> Parsed {
        let xml = try inflate(bytes)
        if nestingDepth(xml, maxXMLDepth) > maxXMLDepth {
            throw PCIOError.format("SVG", "elements are nested more than \(maxXMLDepth) levels deep")
        }
        let root = try parseXML(xml)
        applyStyles(root)
        var warnings: [String] = []
        let ids0 = idMap(root)
        expandUses(root, ids0, &warnings)
        let ids = idMap(root)
        let vb = viewBox(root.attrs["viewBox"])
        let style = computedStyle([:], root)
        let fs = fontSize(style)
        let vbw = vb.map { Double($0.width) }, vbh = vb.map { Double($0.height) }
        var w = length(root.attrs["width"], percentBase: vbw ?? 100, fontSize: fs) ?? vbw ?? 100
        var h = length(root.attrs["height"], percentBase: vbh ?? 100, fontSize: fs) ?? vbh ?? 100
        if !(w > 0) { w = vb.map { Double($0.width) } ?? 100 }
        if !(h > 0) { h = vb.map { Double($0.height) } ?? 100 }
        let rootTransform = vb.map { viewBoxTransform($0, root.attrs["preserveAspectRatio"], width: w, height: h) } ?? .identity
        let viewport = vb.map { $0.size } ?? CGSize(width: w, height: h)
        return Parsed(root: root, ids: ids, size: CGSize(width: w, height: h), rootTransform: rootTransform, viewport: viewport, warnings: warnings)
    }

    /// The plain XML of `bytes`: itself, or the inflated content of a gzip `.svgz`, refused past
    /// `maxInflatedBytes` (a decompression bomb) or when the stream is corrupt.
    static func inflate(_ bytes: [UInt8]) throws -> [UInt8] {
        guard Deflate.isGzip(bytes) else { return bytes }
        do {
            return try Deflate.gunzip(bytes, limit: Int(maxInflatedBytes))
        } catch PCIOError.limitExceeded {
            throw PCIOError.format("SVG", "the compressed SVG inflates past \(maxInflatedBytes >> 20) MB")
        } catch {
            throw PCIOError.format("SVG", "the compressed SVG couldn't be inflated: \(error)")
        }
    }

    /// The deepest element nesting in `xml`, stopping as soon as it passes `limit` (the result
    /// is then `limit + 1`). Comments, CDATA sections, processing instructions and the DOCTYPE
    /// add nothing; quoted attribute values may hold `>` or `/>`. Malformed markup is only
    /// counted loosely: the parser rejects it afterwards.
    static func nestingDepth(_ xml: [UInt8], _ limit: Int) -> Int {
        let n = xml.count
        func after(_ from: Int, _ pat: [UInt8]) -> Int {
            var i = from
            while i + pat.count <= n {
                if xml[i] == pat[0], xml[i ..< i + pat.count].elementsEqual(pat) { return i + pat.count }
                i += 1
            }
            return n
        }
        // The index after a tag's closing `>` (outside quotes) and whether the tag ended in `/>`.
        func tagEnd(_ from: Int) -> (Int, Bool) {
            var quote: UInt8?
            var last: UInt8 = 0x20
            var k = from
            while k < n {
                let b = xml[k]
                if let q = quote {
                    if b == q { quote = nil }
                } else if b == 0x22 || b == 0x27 {
                    quote = b
                } else if b == 0x3E {
                    return (k + 1, last == 0x2F)
                } else if !(b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D) {
                    last = b
                }
                k += 1
            }
            return (n, false)
        }
        func starts(_ at: Int, _ s: String) -> Bool {
            let u = Array(s.utf8)
            return at + u.count <= n && xml[at ..< at + u.count].elementsEqual(u)
        }
        var depth = 0, deepest = 0, i = 0
        while i < n {
            guard let p = xml[i...].firstIndex(of: 0x3C) else { break }
            if starts(p, "<!--") {
                i = after(p + 4, Array("-->".utf8))
            } else if starts(p, "<![CDATA[") {
                i = after(p + 9, Array("]]>".utf8))
            } else if starts(p, "<?") {
                i = after(p + 2, Array("?>".utf8))
            } else if starts(p, "<!") {
                i = tagEnd(p + 2).0
            } else if starts(p, "</") {
                depth = max(0, depth - 1)
                i = tagEnd(p + 2).0
            } else {
                let (end, selfClosing) = tagEnd(p + 1)
                if !selfClosing {
                    depth += 1
                    deepest = max(deepest, depth)
                    if deepest > limit { return deepest }
                }
                i = end
            }
        }
        return deepest
    }

    /// The document canvas for a drawing: its size in px, scaled down to `maxSide` when needed.
    struct Canvas {
        var size: PixelSize
        /// Drawing px → canvas pixels (1 unless the drawing had to shrink).
        var scale: Double
    }

    static func canvas(_ size: CGSize, _ warnings: inout [String]) -> Canvas {
        let w = max(Double(size.width), 1), h = max(Double(size.height), 1)
        let limit = Double(maxSide)
        let scale = min(limit / w, limit / h, 1)
        if scale < 1 {
            warnings.append("SVG: the \(Int(w.rounded())) × \(Int(h.rounded())) px drawing was scaled down to fit \(maxSide) px")
        }
        let side = { (v: Double) -> Int in Int(min(max((v * scale).rounded(), 1), limit)) }
        return Canvas(size: PixelSize(width: side(w), height: side(h)), scale: scale)
    }

    /// The inheritable part of a computed style.
    static func inheritable(_ style: [String: String]) -> [String: String] {
        style.filter { inheritedProperties.contains($0.key) }
    }

    /// Elements never drawn where they stand.
    static let nonRendering: Set<String> = [
        "defs", "title", "desc", "metadata", "style", "script", "symbol", "linearGradient", "radialGradient", "pattern",
        "clipPath", "mask", "filter", "marker", "foreignObject", "stop", "font", "font-face", "cursor", "view",
    ]

    /// Drawable elements in the tree (iterative), stopping past `limit`.
    static func countNodes(_ root: Node, limit: Int) -> Int {
        var n = 0
        var stack = root.children
        while let x = stack.popLast() {
            if x.isText || x.name.hasPrefix(TreeBuilder.foreign) || nonRendering.contains(x.name) { continue }
            n += 1
            if n > limit { return n }
            stack += x.children
        }
        return n
    }

    static func importParsed(_ name: String, _ parsed: Parsed, _ maxGroupDepth: Int) -> ImportResult {
        var warnings = parsed.warnings
        let cv = canvas(parsed.size, &warnings)
        var doc = Document(name: name, size: cv.size, mode: .rgb, depth: .u8)
        let global = CGAffineTransform(scaleX: cv.scale, y: cv.scale)
        let limit: Int? = maxGroupDepth > 0 ? min(max(maxGroupDepth, 1), maxGroupDepthLimit) : nil
        var conv = Conv(fmt: doc.pixelFormat, canvas: doc.bounds, global: global, scale: cv.scale, maxGroupDepth: limit, ids: parsed.ids, warnings: warnings)
        let rootStyle = computedStyle([:], parsed.root)
        if countNodes(parsed.root, limit: maxNodes) > maxNodes {
            conv.warnings.append("SVG: more than \(maxNodes) elements; opened as one pixel layer instead of shapes")
            let xml = standalone(parsed.root.children, ts: then(parsed.rootTransform, global), inherited: inheritable(rootStyle),
                                 rect: doc.bounds, ids: parsed.ids, viewport: parsed.viewport)
            if let bm = renderCoreSVG(xml, doc.bounds) {
                doc.layers.append(Layer(name: "Background", content: .raster(bm.surface(doc.pixelFormat))))
            }
        } else {
            doc.layers = conv.convertChildren(parsed.root.children, rootStyle, parsed.rootTransform, parsed.viewport, depth: 0, rec: 0)
        }
        if doc.layers.isEmpty { conv.warnings.append("SVG: nothing to draw (an empty drawing)") }
        return ImportResult(document: doc, warnings: conv.warnings)
    }

    // MARK: - Conversion

    /// Converts a parsed tree into layers (photocraft `Conv`).
    struct Conv {
        let fmt: PixelFormat
        let canvas: PixelRect
        /// Drawing px → canvas pixels.
        let global: CGAffineTransform
        let scale: Double
        let maxGroupDepth: Int?
        let ids: [String: Node]
        var warnings: [String]
        /// Features already warned about (one warning each).
        var noted: Set<String> = []
        /// Unnamed shapes, groups, images and texts so far, for "Shape 3"-style names.
        var counts = [0, 0, 0, 0]

        init(fmt: PixelFormat, canvas: PixelRect, global: CGAffineTransform, scale: Double, maxGroupDepth: Int?, ids: [String: Node], warnings: [String]) {
            self.fmt = fmt; self.canvas = canvas; self.global = global; self.scale = scale; self.maxGroupDepth = maxGroupDepth
            self.ids = ids; self.warnings = warnings
        }

        mutating func note(_ what: String, _ msg: String) {
            if noted.insert(what).inserted { warnings.append(msg) }
        }

        /// The element's `id`, or a numbered name by kind (0 shape, 1 group, 2 image, 3 text).
        mutating func name(_ id: String, _ kind: Int) -> String {
            if !id.isEmpty { return id }
            counts[kind] += 1
            return "\(["Shape", "Group", "Image", "Text"][kind]) \(counts[kind])"
        }

        /// `nodes` in paint order (first = bottom), as layers in the same order. `parentAbs` maps
        /// the parent's user space to drawing px.
        mutating func convertChildren(_ nodes: [Node], _ parentStyle: [String: String], _ parentAbs: CGAffineTransform, _ viewport: CGSize,
                                      depth: Int, rec: Int) -> [Layer] {
            var out: [Layer] = []
            for n in nodes { convertNode(n, parentStyle, parentAbs, viewport, &out, depth: depth, rec: rec) }
            return out
        }

        /// A reference property that points at an existing element of one of `kinds`.
        /// `nil` when unset (or not a reference), `false` for a reference to nothing usable. A CSS
        /// function (`blur(2px)`, `circle(…)`) counts as set.
        func validRef(_ style: [String: String], _ key: String, _ kinds: Set<String>) -> Bool? {
            guard let v = style[key]?.trimmingCharacters(in: .whitespaces), !v.isEmpty, v != "none" else { return nil }
            guard v.hasPrefix("url(") else { return v.contains("(") ? true : nil }
            guard let id = SVGImport.reference(v), let t = ids[id] else { return false }
            return kinds.contains(t.name)
        }

        func opacity(_ style: [String: String], _ key: String) -> Double {
            guard let s = style[key]?.trimmingCharacters(in: .whitespaces) else { return 1 }
            let v = s.hasSuffix("%") ? (Double(s.dropLast()) ?? 100) / 100 : Double(s) ?? 1
            return v.isFinite ? max(0, min(1, v)) : 1
        }

        static func blendMode(_ s: String?) -> BlendMode {
            switch s?.trimmingCharacters(in: .whitespaces).lowercased() {
            case "multiply": .multiply
            case "screen": .screen
            case "overlay": .overlay
            case "darken": .darken
            case "lighten": .lighten
            case "color-dodge": .colorDodge
            case "color-burn": .colorBurn
            case "hard-light": .hardLight
            case "soft-light": .softLight
            case "difference": .difference
            case "exclusion": .exclusion
            case "hue": .hue
            case "saturation": .saturation
            case "color": .color
            case "luminosity": .luminosity
            default: .normal
            }
        }

        mutating func convertNode(_ n: Node, _ parentStyle: [String: String], _ parentAbs: CGAffineTransform, _ viewport: CGSize,
                                  _ out: inout [Layer], depth: Int, rec: Int) {
            if n.isText || n.name.hasPrefix(TreeBuilder.foreign) || SVGImport.nonRendering.contains(n.name) { return }
            let style = SVGImport.computedStyle(parentStyle, n)
            if style["display"]?.trimmingCharacters(in: .whitespaces) == "none" { return }
            var local = SVGImport.parseTransform(n.attrs["transform"])
            if n.fromUse {
                let fs = SVGImport.fontSize(style, viewport: viewport)
                let x = SVGImport.length(n.attrs["x"], percentBase: viewport.width, fontSize: fs) ?? 0
                let y = SVGImport.length(n.attrs["y"], percentBase: viewport.height, fontSize: fs) ?? 0
                local = SVGImport.then(CGAffineTransform(translationX: x, y: y), local)
            }
            let abs = SVGImport.then(local, parentAbs)
            guard SVGImport.isFinite(abs) else { return }
            // References to missing clip paths, masks or filters disable the element.
            let clip = validRef(style, "clip-path", ["clipPath"])
            let mask = validRef(style, "mask", ["mask"])
            let filter = validRef(style, "filter", ["filter"])
            if clip == false || mask == false || filter == false { return }
            let dropped: [(Bool, String)] = [(filter == true, "filter"), (clip == true, "clip-path"), (mask == true, "mask")]
            let effects = dropped.contains { $0.0 }
            let opacity = opacity(style, "opacity")
            let blend = Conv.blendMode(style["mix-blend-mode"])

            switch n.name {
            case "g", "a", "switch", "svg":
                var children = n.children
                if n.name == "switch" { children = Array(children.filter { !$0.isText && !$0.name.hasPrefix(TreeBuilder.foreign) }.prefix(1)) }
                var inner = abs
                var innerViewport = viewport
                var viewportClip = false
                if n.name == "svg" {
                    // A nested viewport (an inline `svg`, or a `symbol` through `use`).
                    let fs = SVGImport.fontSize(style, viewport: viewport)
                    let x = SVGImport.length(n.attrs["x"], percentBase: viewport.width, fontSize: fs) ?? 0
                    let y = SVGImport.length(n.attrs["y"], percentBase: viewport.height, fontSize: fs) ?? 0
                    let w = SVGImport.length(n.attrs["width"] ?? "100%", percentBase: viewport.width, fontSize: fs) ?? viewport.width
                    let h = SVGImport.length(n.attrs["height"] ?? "100%", percentBase: viewport.height, fontSize: fs) ?? viewport.height
                    guard w > 0, h > 0 else { return }
                    let vb = SVGImport.viewBox(n.attrs["viewBox"])
                    var t = CGAffineTransform(translationX: x, y: y)
                    if let vb { t = SVGImport.then(SVGImport.viewBoxTransform(vb, n.attrs["preserveAspectRatio"], width: w, height: h), t) }
                    inner = SVGImport.then(t, abs)
                    innerViewport = vb?.size ?? CGSize(width: w, height: h)
                    let overflow = style["overflow"]?.trimmingCharacters(in: .whitespaces).lowercased()
                    let rectGiven = ["x", "y", "width", "height"].contains { n.attrs[$0] != nil } || n.attrs["pc:symbol"] != nil
                    viewportClip = overflow != "visible" && overflow != "auto" && rectGiven
                }
                let tooDeep = maxGroupDepth.map { depth >= $0 } == true || depth >= maxGroupDepthLimit || rec >= SVGImport.maxRecursion
                if effects || tooDeep || viewportClip {
                    for (yes, what) in dropped where yes {
                        note(what, "SVG: a group with a \(what) was rasterised, so it is not editable as shapes")
                    }
                    if viewportClip { note("clip-path", "SVG: a group with a clip-path was rasterised, so it is not editable as shapes") }
                    if tooDeep { note("depth", "SVG: groups nested too deeply were rasterised") }
                    let name = name(n.id, 1)
                    if let l = rasterLayer(n, name, parentStyle, parentAbs, viewport) { out.append(l) }
                    return
                }
                // A group that only carries a transform adds nothing to the layer tree.
                let plain = n.id.isEmpty && opacity >= 1 && blend == .normal
                let kids = convertChildren(children, style, inner, innerViewport, depth: plain ? depth : depth + 1, rec: n.isTrivialGroup ? rec : rec + 1)
                if kids.isEmpty { return }
                if plain {
                    out += kids
                    return
                }
                if opacity >= 1, blend == .normal, kids.count == 1, var child = kids.first {
                    child.name = n.id
                    out.append(child)
                    return
                }
                var l = Layer(name: name(n.id, 1), content: .group(LayerGroup(children: kids, expanded: false)))
                l.opacity = Float(opacity)
                l.blend = blend
                out.append(l)
            case "path", "rect", "circle", "ellipse", "line", "polyline", "polygon":
                if effects {
                    for (yes, what) in dropped where yes {
                        note(what, "SVG: a group with a \(what) was rasterised, so it is not editable as shapes")
                    }
                    if let l = rasterLayer(n, name(n.id, 1), parentStyle, parentAbs, viewport) { out.append(l) }
                    return
                }
                if var l = shapeLayer(n, style, abs, parentStyle, parentAbs, viewport) {
                    // A rasterised shape already has its opacity in its pixels.
                    if case .shape = l.content { l.opacity = Float(opacity) }
                    l.blend = blend
                    out.append(l)
                }
            case "image":
                guard style["visibility"]?.trimmingCharacters(in: .whitespaces) != "hidden", SVGImport.imageData(n) != nil else { return }
                note("image", "SVG: embedded images are pixel layers")
                if let l = rasterLayer(n, name(n.id, 2), parentStyle, parentAbs, viewport) { out.append(l) }
            case "text":
                let hasTextPath = { () -> Bool in
                    var stack = n.children
                    while let c = stack.popLast() {
                        if c.name == "textPath" { return true }
                        stack += c.children
                    }
                    return false
                }()
                let vertical = (style["writing-mode"] ?? "").hasPrefix("tb")
                if effects || hasTextPath || vertical {
                    for (yes, what) in dropped where yes {
                        note(what, "SVG: a group with a \(what) was rasterised, so it is not editable as shapes")
                    }
                    if hasTextPath || vertical { note("text-path", "SVG: text on a path or set vertically was rasterised") }
                    if let l = rasterLayer(n, name(n.id, 3), parentStyle, parentAbs, viewport) { out.append(l) }
                    return
                }
                let runs = SVGImport.textRuns(n, style: style, viewport: viewport)
                var kids: [Layer] = []
                for r in runs {
                    let runNode = Node(name: "path")
                    if let l = shapeLayer(runNode, r.style, abs, parentStyle, parentAbs, viewport, geometry: r.path) { kids.append(l) }
                }
                if kids.isEmpty {
                    if !SVGImport.textContent(n).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        note("text", "SVG: text needs a font the drawing can use; none matched, so it was dropped")
                    }
                    return
                }
                let content = SVGImport.textContent(n).trimmingCharacters(in: .whitespacesAndNewlines)
                let name = !n.id.isEmpty ? n.id : content.isEmpty ? name("", 3) : String(content.prefix(31))
                var l = Layer(name: name, content: .group(LayerGroup(children: kids, expanded: false)))
                l.opacity = Float(opacity)
                l.blend = blend
                out.append(l)
            default:
                return
            }
        }

        /// A path as a shape layer, or a pixel layer when its paint is a pattern or it has
        /// markers (photocraft `shape_layer`). `geometry` overrides the element's own (text runs).
        mutating func shapeLayer(_ n: Node, _ style: [String: String], _ abs: CGAffineTransform, _ parentStyle: [String: String],
                                 _ parentAbs: CGAffineTransform, _ viewport: CGSize, geometry: CGPath? = nil) -> Layer? {
            if style["visibility"]?.trimmingCharacters(in: .whitespaces) == "hidden" { return nil }
            let fs = SVGImport.fontSize(style, viewport: viewport)
            guard let user = geometry ?? SVGImport.shapePath(n, viewport: viewport, fontSize: fs), !user.isEmpty else { return nil }
            let bbox = user.boundingBoxOfPath
            let fillPaint = SVGImport.paint(style["fill"] ?? "black", style, ids, bbox: bbox, viewport: viewport)
            let strokePaint = SVGImport.paint(style["stroke"], style, ids, bbox: bbox, viewport: viewport)
            let isPattern = { (p: Paint?) -> Bool in if case .pattern = p { true } else { false } }
            let hasMarkers = geometry == nil && ["path", "line", "polyline", "polygon"].contains(n.name)
                && ["marker-start", "marker-mid", "marker-end"].contains { validRef(style, $0, ["marker"]) == true }
            if isPattern(fillPaint) || isPattern(strokePaint) || hasMarkers {
                if hasMarkers {
                    note("marker", "SVG: shapes with markers were rasterised, so they are not editable as shapes")
                } else {
                    note("pattern", "SVG: pattern paints were rasterised, so those shapes are not editable")
                }
                return rasterLayer(n, name(n.id, 0), parentStyle, parentAbs, viewport)
            }
            let ts = SVGImport.then(abs, global)
            var t = ts
            guard let canvasPath = user.copy(using: &t) else { return nil }
            let subpaths = SVGImport.knots(canvasPath)
            if subpaths.isEmpty { return nil }
            let fillOpacity = opacity(style, "fill-opacity")
            var fill: Fill?
            var fillDraw: (Paint, Double)?
            if let p = fillPaint {
                fill = modelFill(p, fillOpacity, ts)
                fillDraw = (p, fillOpacity)
            }
            var stroke: ShapeStroke?
            var strokeDraw: StrokeDraw?
            if let p = strokePaint {
                // Stroke widths are in user units; under a non-uniform scale they take the
                // geometric mean, the one width the shape model has.
                let kx = (ts.a * ts.a + ts.b * ts.b).squareRoot(), ky = (ts.c * ts.c + ts.d * ts.d).squareRoot()
                if Swift.abs(kx - ky) > 0.01 * max(kx, ky) {
                    note("stroke-scale", "SVG: strokes under a non-uniform scale keep one averaged width")
                }
                let k = max(Swift.abs(ts.a * ts.d - ts.c * ts.b).squareRoot(), 1e-6)
                let diag = ((viewport.width * viewport.width + viewport.height * viewport.height) / 2).squareRoot()
                let sw = SVGImport.length(style["stroke-width"], percentBase: diag, fontSize: fs) ?? 1
                if sw > 0 {
                    var colorAlpha = 1.0
                    var modelPaint = p
                    if case var .color(c) = p {
                        colorAlpha = c.a
                        c.a = 1
                        modelPaint = .color(c)
                    }
                    let strokeOpacity = opacity(style, "stroke-opacity") * colorAlpha
                    let width = max(sw * k, 0.01)
                    var dashes = SVGImport.numbers(style["stroke-dasharray"]?.replacingOccurrences(of: "px", with: ""))
                    if dashes.contains(where: { $0 < 0 }) || dashes.reduce(0, +) <= 0 { dashes = [] }
                    if dashes.count % 2 == 1 { dashes += dashes }
                    let offset = SVGImport.length(style["stroke-dashoffset"], percentBase: diag, fontSize: fs) ?? 0
                    let cap: (LineCap, CGLineCap) = switch style["stroke-linecap"]?.trimmingCharacters(in: .whitespaces) {
                    case "round": (.round, .round)
                    case "square": (.square, .square)
                    default: (.butt, .butt)
                    }
                    let join: (LineJoin, CGLineJoin) = switch style["stroke-linejoin"]?.trimmingCharacters(in: .whitespaces) {
                    case "round": (.round, .round)
                    case "bevel": (.bevel, .bevel)
                    default: (.miter, .miter)
                    }
                    var miter = Double(style["stroke-miterlimit"]?.trimmingCharacters(in: .whitespaces) ?? "4") ?? 4
                    if !(miter >= 1) || !miter.isFinite { miter = miter.isFinite ? 1 : 4 }
                    stroke = ShapeStroke(width: Float(width), paint: modelFill(modelPaint, 1, ts), opacity: Float(strokeOpacity), align: .center,
                                         cap: cap.0, join: join.0, miterLimit: Float(miter),
                                         dashes: dashes.map { Float($0 * k / width) }, dashOffset: Float(offset * k / width))
                    strokeDraw = StrokeDraw(paint: modelPaint, opacity: strokeOpacity, width: width, cap: cap.1, join: join.1, miterLimit: miter,
                                            dashes: dashes.map { $0 * k }, dashOffset: offset * k)
                }
            }
            let evenOdd = style["fill-rule"]?.trimmingCharacters(in: .whitespaces) == "evenodd"
            var sh = ShapeLayer(path: VectorPath(subpaths, fillRule: evenOdd ? .evenOdd : .nonZero, inverted: false), fill: fill, stroke: stroke)
            sh.cache = SVGImport.renderShape(path: canvasPath, evenOdd: evenOdd, fill: fillDraw, stroke: strokeDraw, paintToCanvas: ts,
                                             canvas: canvas, format: fmt)
            return Layer(name: name(n.id, 0), content: .shape(sh))
        }

        /// A paint as a layer fill. `ts` maps the paint's user space onto the canvas.
        mutating func modelFill(_ p: Paint, _ opacity: Double, _ ts: CGAffineTransform) -> Fill {
            func pc(_ c: RGBA, _ a: Double) -> PCColor {
                PCColor.rgb(Float(c.r), Float(c.g), Float(c.b), Float(max(0, min(1, a))))
            }
            switch p {
            case let .color(c):
                return .solid(pc(c, c.a * opacity))
            case let .gradient(g):
                note("gradient", "SVG: gradient paints keep their stops and direction, not their exact geometry")
                let stops = g.stops.map { ColorStop(Float($0.offset), pc($0.color, $0.color.a * opacity)) }
                var angle: Float = 0
                if !g.radial {
                    let m = SVGImport.then(g.transform, ts)
                    let a = CGPoint(x: g.x1, y: g.y1).applying(m), b = CGPoint(x: g.x2, y: g.y2).applying(m)
                    // Photoshop's angle: 0° left → right, counter-clockwise positive (y points down).
                    let deg = atan2(-(b.y - a.y), b.x - a.x) * 180 / .pi
                    angle = deg.isFinite ? Float(deg) : 0
                }
                return .gradient(GradientFill(stops: stops, angle: angle, scale: 1, style: g.radial ? .radial : .linear, reverse: false,
                                              opacityStops: [], midpoints: [], offset: .zero, dither: false, align: true))
            case .pattern:
                // Pattern paints are rasterised before we get here.
                return .solid(PCColor.rgb(0.5, 0.5, 0.5, Float(opacity)))
            }
        }

        /// The element rendered by CoreSVG into a pixel layer over its bounding box, clipped to the
        /// canvas (photocraft `raster_layer`).
        mutating func rasterLayer(_ n: Node, _ name: String, _ parentStyle: [String: String], _ parentAbs: CGAffineTransform, _ viewport: CGSize) -> Layer? {
            let ts = SVGImport.then(parentAbs, global)
            var bounds = SVGImport.bounds(n, SVGImport.computedStyle(parentStyle, n), ts, viewport, ids)
            if bounds.isNull || bounds.isEmpty { bounds = canvas.cgRect }
            let rect = SVGImport.pixelRect(bounds.insetBy(dx: -2, dy: -2), canvas)
            if rect.isEmpty { return nil }
            guard UInt64(rect.width) * UInt64(rect.height) <= SVGImport.maxRasterPixels else {
                note("raster-size", "SVG: an element too large to rasterise was dropped")
                return nil
            }
            let xml = SVGImport.standalone([n], ts: ts, inherited: SVGImport.inheritable(parentStyle), rect: rect, ids: ids, viewport: viewport)
            guard let bm = SVGImport.renderCoreSVG(xml, rect) else {
                note("raster-fail", "SVG: an element CoreSVG could not render was dropped")
                return nil
            }
            return Layer(name: name, content: .raster(bm.surface(fmt)))
        }
    }

    // MARK: - Bounds

    /// The decoded bytes of an `<image>`'s `data:` URL (other references are never read).
    static func imageData(_ n: Node) -> [UInt8]? {
        guard let href = n.attrs["href"]?.trimmingCharacters(in: .whitespacesAndNewlines), href.lowercased().hasPrefix("data:"),
              let comma = href.firstIndex(of: ",") else { return nil }
        let meta = href[href.index(href.startIndex, offsetBy: 5) ..< comma].lowercased()
        let payload = String(href[href.index(after: comma)...])
        if meta.hasSuffix(";base64") {
            let clean = payload.filter { !$0.isWhitespace }
            return Data(base64Encoded: clean, options: .ignoreUnknownCharacters).map { [UInt8]($0) }
        }
        return payload.removingPercentEncoding.map { Array($0.utf8) }
    }

    /// A conservative canvas bounding box of what `n` draws (strokes, filter regions and images
    /// included); null when nothing is known.
    static func bounds(_ n: Node, _ style: [String: String], _ ts: CGAffineTransform, _ viewport: CGSize, _ ids: [String: Node]) -> CGRect {
        if n.isText || nonRendering.contains(n.name) || style["display"]?.trimmingCharacters(in: .whitespaces) == "none" { return .null }
        var local = parseTransform(n.attrs["transform"])
        if n.fromUse {
            let x = length(n.attrs["x"], percentBase: viewport.width) ?? 0
            let y = length(n.attrs["y"], percentBase: viewport.height) ?? 0
            local = then(CGAffineTransform(translationX: x, y: y), local)
        }
        var t = then(local, ts)
        guard isFinite(t) else { return .null }
        let fs = fontSize(style, viewport: viewport)
        var out = CGRect.null
        var userBox = CGRect.null
        switch n.name {
        case "path", "rect", "circle", "ellipse", "line", "polyline", "polygon":
            guard let p = shapePath(n, viewport: viewport, fontSize: fs) else { return .null }
            userBox = p.boundingBoxOfPath
            out = p.boundingBoxOfPath.applying(t)
            if let s = style["stroke"], s != "none" {
                let diag = ((viewport.width * viewport.width + viewport.height * viewport.height) / 2).squareRoot()
                let sw = length(style["stroke-width"], percentBase: diag, fontSize: fs) ?? 1
                let k = max((t.a * t.a + t.b * t.b).squareRoot(), (t.c * t.c + t.d * t.d).squareRoot())
                let miter = max(1, Double(style["stroke-miterlimit"] ?? "4") ?? 4)
                out = out.insetBy(dx: -sw * k * min(miter, 10) / 2, dy: -sw * k * min(miter, 10) / 2)
            }
            // Markers can reach anywhere near the path.
            if ["marker-start", "marker-mid", "marker-end"].contains(where: { style[$0] != nil && style[$0] != "none" }) {
                out = out.insetBy(dx: -max(out.width, 50), dy: -max(out.height, 50))
            }
        case "image":
            let x = length(n.attrs["x"], percentBase: viewport.width, fontSize: fs) ?? 0
            let y = length(n.attrs["y"], percentBase: viewport.height, fontSize: fs) ?? 0
            var w = length(n.attrs["width"], percentBase: viewport.width, fontSize: fs)
            var h = length(n.attrs["height"], percentBase: viewport.height, fontSize: fs)
            if w == nil || h == nil, let d = imageData(n), let src = CGImageSourceCreateWithData(Data(d) as CFData, nil),
               let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
                w = w ?? (props[kCGImagePropertyPixelWidth] as? Double)
                h = h ?? (props[kCGImagePropertyPixelHeight] as? Double)
                if n.attrs["width"] == nil, let w { n.attrs["width"] = "\(w)" }
                if n.attrs["height"] == nil, let h { n.attrs["height"] = "\(h)" }
            }
            userBox = CGRect(x: x, y: y, width: w ?? 0, height: h ?? 0)
            out = userBox.applying(t)
        case "text":
            let runs = textRuns(n, style: style, viewport: viewport)
            if runs.isEmpty {
                // Without outlines (text on a path, unusual fonts): the whole viewport.
                userBox = CGRect(origin: .zero, size: viewport)
            } else {
                for r in runs { userBox = userBox.union(r.path.boundingBoxOfPath) }
                userBox = userBox.insetBy(dx: -fs, dy: -fs)
            }
            out = userBox.applying(t)
        case "g", "a", "switch", "svg":
            var inner = t
            var vp = viewport
            if n.name == "svg" {
                let x = length(n.attrs["x"], percentBase: viewport.width, fontSize: fs) ?? 0
                let y = length(n.attrs["y"], percentBase: viewport.height, fontSize: fs) ?? 0
                let w = length(n.attrs["width"] ?? "100%", percentBase: viewport.width, fontSize: fs) ?? viewport.width
                let h = length(n.attrs["height"] ?? "100%", percentBase: viewport.height, fontSize: fs) ?? viewport.height
                var m = CGAffineTransform(translationX: x, y: y)
                if let vb = viewBox(n.attrs["viewBox"]) {
                    m = then(viewBoxTransform(vb, n.attrs["preserveAspectRatio"], width: w, height: h), m)
                    vp = vb.size
                } else {
                    vp = CGSize(width: w, height: h)
                }
                inner = then(m, t)
                t = inner
            }
            for c in n.children {
                out = out.union(bounds(c, computedStyle(style, c), inner, vp, ids))
            }
            // Bounding box in this element's user space, for the filter region.
            if !out.isNull { userBox = out.applying(t.inverted()) }
        default:
            return .null
        }
        // A filter can paint its whole region.
        if let id = reference(style["filter"]), let f = ids[id], !userBox.isNull {
            let userUnits = f.attrs["filterUnits"] == "userSpaceOnUse"
            func v(_ k: String, _ def: Double, _ base: Double) -> Double {
                guard let s = f.attrs[k] else { return def }
                if !userUnits, !s.hasSuffix("%") { return Double(s) ?? def }
                return length(s, percentBase: userUnits ? base : 1) ?? def
            }
            let fx = v("x", -0.1, viewport.width), fy = v("y", -0.1, viewport.height)
            let fw = v("width", 1.2, viewport.width), fh = v("height", 1.2, viewport.height)
            let region = userUnits ? CGRect(x: fx, y: fy, width: fw, height: fh)
                : CGRect(x: userBox.minX + fx * userBox.width, y: userBox.minY + fy * userBox.height, width: fw * userBox.width, height: fh * userBox.height)
            out = out.union(region.applying(t))
        }
        return out
    }
}
