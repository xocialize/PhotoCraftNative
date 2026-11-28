// Port of photocraft-affinity (crates/affinity/src/model.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
// The document model PhotoCraft imports: spreads, artboards, layers, groups, curves, shapes, text and
// images, with transforms composed into document space. Anything else is reported by
// `Document.warnings` instead of being dropped silently.

extension Affinity {
    /// Affine map `x' = a·x + c·y + e`, `y' = b·x + d·y + f` (kurbo's coefficient order).
    public struct Affine: Equatable, Sendable {
        public var a: Double
        public var b: Double
        public var c: Double
        public var d: Double
        public var e: Double
        public var f: Double

        public init(_ a: Double, _ b: Double, _ c: Double, _ d: Double, _ e: Double, _ f: Double) {
            self.a = a
            self.b = b
            self.c = c
            self.d = d
            self.e = e
            self.f = f
        }

        public static let identity = Affine(1, 0, 0, 1, 0, 0)

        /// The six coefficients in kurbo order `[a, b, c, d, e, f]`.
        public var coefficients: [Double] { [a, b, c, d, e, f] }

        /// Affinity's `Xfrm`, stored row by row: (a, c, e, b, d, f).
        static func fromXfrm(_ m: [Double]) -> Affine {
            Affine(m[0], m[3], m[1], m[4], m[2], m[5])
        }

        /// This map followed by `outer`.
        public func then(_ outer: Affine) -> Affine {
            let o = outer
            return Affine(
                o.a * a + o.c * b, o.b * a + o.d * b,
                o.a * c + o.c * d, o.b * c + o.d * d,
                o.a * e + o.c * f + o.e, o.b * e + o.d * f + o.f
            )
        }

        public func apply(_ p: Point) -> Point {
            Point(x: a * p.x + c * p.y + e, y: b * p.x + d * p.y + f)
        }

        /// Geometric mean of the axis scales: how much a stroke width or font size grows.
        public var scale: Double {
            abs(a * d - b * c).squareRoot()
        }

        public var isFinite: Bool {
            a.isFinite && b.isFinite && c.isFinite && d.isFinite && e.isFinite && f.isFinite
        }
    }

    public struct Point: Equatable, Sendable {
        public var x: Double
        public var y: Double

        public init(x: Double, y: Double) {
            self.x = x
            self.y = y
        }
    }

    public struct Rect: Equatable, Sendable {
        public var x0: Double
        public var y0: Double
        public var x1: Double
        public var y1: Double

        public init(x0: Double, y0: Double, x1: Double, y1: Double) {
            self.x0 = x0
            self.y0 = y0
            self.x1 = x1
            self.y1 = y1
        }

        static let zero = Rect(x0: 0, y0: 0, x1: 0, y1: 0)
    }

    /// A cubic segment: two controls and the end point (photocraft's `[Point; 3]`).
    public struct Segment: Equatable, Sendable {
        public var c1: Point
        public var c2: Point
        public var end: Point

        public init(_ c1: Point, _ c2: Point, _ end: Point) {
            self.c1 = c1
            self.c2 = c2
            self.end = end
        }

        func map(_ m: Affine) -> Segment {
            Segment(m.apply(c1), m.apply(c2), m.apply(end))
        }
    }

    /// One cubic Bézier subpath, in document pixels.
    public struct SubPath: Equatable, Sendable {
        public var start: Point
        public var segments: [Segment]
        public var closed: Bool

        public init(start: Point, segments: [Segment], closed: Bool) {
            self.start = start
            self.segments = segments
            self.closed = closed
        }
    }

    /// An outline in document pixels.
    public struct Path: Equatable, Sendable {
        public var subpaths: [SubPath]

        public init(subpaths: [SubPath] = []) {
            self.subpaths = subpaths
        }

        public func transformed(_ m: Affine) -> Path {
            Path(subpaths: subpaths.map { SubPath(start: m.apply($0.start), segments: $0.segments.map { $0.map(m) }, closed: $0.closed) })
        }
    }

    /// Affinity's blend modes, numbered by the `Blnd` enum.
    public enum Blend: Sendable, CaseIterable {
        case normal, passThrough, darken, darkerColor, multiply, colorBurn, lighten, lighterColor
        case screen, colorDodge, add, overlay, softLight, hardLight, vividLight, pinLight, linearLight
        case hardMix, difference, exclusion, subtract, hue, saturation, luminosity, color
        case average, negation, reflect, glow, erase

        /// The enum (id, version) pairs observed in a document whose layers are named after their mode.
        static func fromEnum(_ id: UInt16, _ version: UInt16) -> Blend? {
            switch (id, version) {
            case (0, _): .normal
            case (1, 0): .darken
            case (2, 1): .darkerColor
            case (2, 0): .multiply
            case (3, 0): .colorBurn
            case (4, 0): .lighten
            case (6, 1): .lighterColor
            case (5, 0): .screen
            case (6, 0): .colorDodge
            case (7, 0): .add
            case (8, 0): .overlay
            case (9, 0): .softLight
            case (10, 0): .hardLight
            case (11, 0): .vividLight
            case (12, 0): .pinLight
            case (15, 1): .linearLight
            case (13, 0): .hardMix
            case (14, 0): .difference
            case (15, 0): .exclusion
            case (16, 0): .subtract
            case (17, 0): .hue
            case (18, 0): .saturation
            case (19, 0): .luminosity
            case (20, 0): .color
            case (21, 0): .average
            case (22, 0): .negation
            case (23, 0): .reflect
            case (24, 0): .glow
            case (25, 0): .erase
            default: nil
            }
        }
    }

    /// A run of text with one set of character attributes.
    public struct TextRun: Equatable, Sendable {
        public var text: String
        /// PostScript name and family of the chosen font.
        public var postscript: String
        public var family: String
        /// CSS weight (400 regular, 700 bold).
        public var weight: Int64
        public var italic: Bool
        /// Font size in document pixels, before the node's transform.
        public var size: Double
        /// Tracking in em.
        public var tracking: Double
        /// Fixed line pitch in document pixels, when the run overrides automatic leading.
        public var leading: Double?
        public var fill: Paint
    }

    public struct Text: Equatable, Sendable {
        public enum Align: Sendable {
            case left, center, right, justify
        }

        public var runs: [TextRun]
        public var align: Align
        /// Artistic text: the first baseline's anchor point in node space (start, centre or end of
        /// the line according to `align`). Frame text: the frame box in node space.
        public var anchor: Point
        public var frame: Rect?
        /// Node space to document pixels.
        public var transform: Affine
    }

    public enum Pixels: Equatable, Sendable {
        /// Straight-alpha RGBA, 8 bits per channel, row by row.
        case rgba8([UInt8])
        /// The original file a placed image was made from (PNG, JPEG…), as embedded.
        case encoded([UInt8])
    }

    public struct Image: Equatable, Sendable {
        public var width: UInt32
        public var height: UInt32
        public var pixels: Pixels
        /// Pixel space (0..w, 0..h) to document pixels.
        public var transform: Affine
    }

    public struct Node: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            /// Layer container (`Scop`).
            case layer
            case group
            /// Artboard: a rectangle that clips its children; `background` paints behind them.
            case artboard(rect: Rect, background: [Paint])
            /// Curve, parametric shape or compound shape: an outline with its fills and strokes.
            /// Children of a shape are clipped by its outline (painted over its fills, under its strokes).
            case shape(path: Path, fills: [Paint], strokes: [Stroke], evenOdd: Bool)
            case text(Text)
            case image(Image)
            /// Something this reader does not import; its children are still imported.
            case unsupported
        }

        public var classTag: Tag
        public var name: String
        public var visible: Bool
        public var locked: Bool
        public var opacity: Double
        public var blend: Blend
        public var kind: Kind
        /// Vector mask in document pixels: the node shows only inside it (nonzero fill).
        public var mask: Path?
        /// Pixel mask: grey levels (white shows the node, black hides it); outside it the node is hidden.
        public var pixelMask: Image?
        /// Bottom to top.
        public var children: [Node]
    }

    public struct Spread: Equatable, Sendable {
        /// Spread bounds in document pixels (the canvas, or the union of the artboards).
        public var bounds: Rect
        /// Pages of a Publisher-style spread (one, or two facing pages), in document pixels.
        public var pages: [Rect]
        /// Transparent background; otherwise the page is white.
        public var transparent: Bool
        /// Bottom to top.
        public var nodes: [Node]
    }

    public struct Document: Equatable, Sendable {
        /// Pixels per inch: all geometry is in document pixels at this resolution.
        public var dpi: Double
        public var spreads: [Spread]
        /// Application that last saved the file, as stored (`Affinity 3.0.2`), when present.
        public var savedBy: String?
        /// Content that was not imported or was approximated, one line per kind, deduplicated.
        public var warnings: [String]
    }

    /// Deepest layer nesting followed; deeper content is reported, not imported.
    static let maxTreeDepth = 128
    /// Total layer nodes imported.
    static let maxNodes = 500_000

    /// Read a document: archive, `doc.dat` and the model.
    public static func read(_ bytes: [UInt8], limits: Limits = .default) throws(AffinityError) -> Document {
        var archive = try Archive(bytes, limits: limits)
        let doc = try archive.read("doc.dat")
        let s = try Stream.parse(doc)
        return try Reader(s, archive).document()
    }

    final class Reader {
        let s: Stream
        var archive: Archive
        var dpi: Double = 72
        private var warnings: [String: Int] = [:]
        private var nodes = 0
        private var active = Set<ObjID>()
        /// Document-wide budgets for expanding outlines (photocraft #6486, `bf321f0f5`). Geometry is
        /// expanded per occurrence, so a compound that lists one shared child twice per level
        /// doubles the work at each level: the depth limit alone allows 2^depth visits.
        private var outlineVisitsLeft = 500_000
        private var outlinePointsLeft = 4_000_000
        private var outlineBudgetWarned = false

        /// Charges one outline call; false once the document's budget is spent.
        func chargeOutlineVisit() -> Bool {
            if outlineVisitsLeft > 0 { outlineVisitsLeft -= 1; return true }
            outlineBudgetExhausted()
            return false
        }

        /// Charges the points of a leaf outline or of a copy into a compound, before the copy.
        func chargeOutlinePoints(_ path: Path) -> Bool {
            var points = 0
            for sp in path.subpaths { points += 1 + sp.segments.count * 3 }
            if points <= outlinePointsLeft { outlinePointsLeft -= points; return true }
            // No more leaves are built for later roots either.
            outlineVisitsLeft = 0
            outlineBudgetExhausted()
            return false
        }

        private func outlineBudgetExhausted() {
            if !outlineBudgetWarned { outlineBudgetWarned = true; warn("compound geometry budget exhausted; some shapes were not imported") }
        }

        init(_ s: Stream, _ archive: Archive) {
            self.s = s
            self.archive = archive
        }

        func warn(_ what: String) {
            warnings[what, default: 0] += 1
        }

        func document() throws(AffinityError) -> Document {
            let root = s.root
            dpi = s.obj(root, "UVCn").flatMap { s.f64($0, "UPPI") }.flatMap { $0 > 0 && $0 < 100_000 ? $0 : nil } ?? 72
            let savedBy = s.obj(root, "NVer").map { v -> String in
                let product = s.str(v, "Prod") ?? "Affinity"
                if let a = s.int(v, "Majr"), let b = s.int(v, "Minr"), let c = s.int(v, "Bild") {
                    return "\(product) \(a).\(b).\(c)"
                }
                return product
            }
            guard let doc = s.obj(root, "DocR") else { throw .malformed("document has no root node") }
            var spreads: [Spread] = []
            for spread in s.objs(doc, "Chld") {
                guard s.isClass(spread, "Sprd") else {
                    warn("an unknown kind of page")
                    continue
                }
                let pages = Affinity.pages(s, spread)
                let defaultSize = s.floats(doc, "DfSz", count: 2).flatMap { v in
                    v[0] > 0 && v[1] > 0 ? Rect(x0: 0, y0: 0, x1: v[0], y1: v[1]) : nil
                }
                let bounds = s.floats(spread, "SprB", count: 4).map(Affinity.rect)
                    ?? pages.dropFirst().reduce(pages.first) { acc, r in acc.map { union($0, r) } }
                    ?? defaultSize
                    ?? Rect.zero
                let transparent = s.bool(spread, "SprT") ?? false
                let (nodes, mask) = try tree(spread, .identity)
                if mask != nil { warn("mask layers directly on a page (imported without them)") }
                spreads.append(Spread(bounds: bounds, pages: pages, transparent: transparent, nodes: nodes))
            }
            guard !spreads.isEmpty else { throw .malformed("document has no pages") }
            if !s.objs(doc, "MpCh").isEmpty {
                warn("master pages (their content is not placed on the pages that use them)")
            }
            // photocraft keeps warnings in a BTreeMap: sorted by bytes.
            let lines = warnings.sorted { $0.key.utf8.lexicographicallyPrecedes($1.key.utf8) }
                .map { $0.value > 1 ? "\($0.key) (\($0.value)×)" : $0.key }
            return Document(dpi: dpi, spreads: spreads, savedBy: savedBy, warnings: lines)
        }

        /// A layer whose children are being read: photocraft's `node` → `children` → `node`
        /// recursion, kept on an explicit stack so a tree 128 layers deep needs no deep call stack.
        private struct Pending {
            /// The layer itself; nil for the spread, which only collects its children.
            var node: Node?
            var id: ObjID
            var world: Affine
            var depth: Int
            var children: [ObjID]
            var next = 0
            var out: [Node] = []
            var mask: Image?
        }

        /// The children of `parent` (a spread), and the pixel mask a mask layer among them puts on it.
        func tree(_ parent: ObjID, _ world: Affine) throws(AffinityError) -> ([Node], Image?) {
            var stack = [Pending(node: nil, id: parent, world: world, depth: 0, children: s.objs(parent, "Chld"))]
            while var top = stack.popLast() {
                if top.next < top.children.count {
                    let c = top.children[top.next]
                    top.next += 1
                    if s.isClass(c, "MRst") {
                        // A mask layer inside a group or layer masks that container.
                        if s.bool(c, "Visi") != false {
                            let local = s.floats(c, "Xfrm", count: 6).map(Affine.fromXfrm) ?? .identity
                            if let m = try Raster.mask(self, c, local.then(top.world)) {
                                if top.mask == nil {
                                    top.mask = m
                                } else {
                                    warn("several pixel masks on one layer (only the first is used)")
                                }
                            }
                        }
                        stack.append(top)
                        continue
                    }
                    let depth = top.depth + 1
                    let parentWorld = top.world
                    stack.append(top)
                    if let (node, world) = try begin(c, parentWorld, depth) {
                        // A compound's children are its operands, already merged into its outline.
                        let children = node.classTag == "Comp" ? [] : s.objs(c, "Chld")
                        stack.append(Pending(node: node, id: c, world: world, depth: depth, children: children))
                    }
                    continue
                }
                guard var node = top.node else { return (top.out, top.mask) }
                // Every child is read: attached masks, then the layer is complete.
                let (mask, attachedMask) = try attachedMasks(top.id, top.world)
                node.mask = mask
                node.pixelMask = attachedMask ?? top.mask
                node.children = top.out
                active.remove(top.id)
                if s.objs(top.id, "FiEf").contains(where: { s.bool($0, "Enab") != false }) {
                    warn("layer effects (shadows, glows, outlines, bevels…)")
                }
                if var parent = stack.popLast() {
                    parent.out.append(node)
                    stack.append(parent)
                }
            }
            return ([], nil)
        }

        /// Everything about layer `id` that comes before its children (photocraft's `node` up to the
        /// recursion), with its world transform; nil when it is skipped.
        func begin(_ id: ObjID, _ parent: Affine, _ depth: Int) throws(AffinityError) -> (Node, Affine)? {
            if depth > maxTreeDepth {
                warn("layers nested deeper than 128 levels")
                return nil
            }
            nodes += 1
            guard nodes <= maxNodes else { throw .limit("too many layers") }
            // A node that contains itself (a shared object linked back into its own subtree).
            guard active.insert(id).inserted else {
                warn("a layer that contains itself")
                return nil
            }
            let local = s.floats(id, "Xfrm", count: 6).map(Affine.fromXfrm) ?? .identity
            let world = local.then(parent)
            let cls = s.classTag(id) ?? Tag(0)
            let name = s.str(id, "Desc") ?? ""
            let visible = s.bool(id, "Visi") ?? true
            let locked = s.bool(id, "Edtb").map { !$0 } ?? false
            let opacity = s.f64(id, "Opac").map { Affinity.clamp($0, 0, 1) } ?? 1
            let blend: Blend
            if case let (i, v)? = s.enumeration(id, "Blnd") {
                if let b = Blend.fromEnum(i, v) {
                    blend = b
                } else {
                    warn("an unknown blend mode (imported as Normal)")
                    blend = .normal
                }
            } else if s.bool(id, "PasT") != false, isContainer(cls) {
                blend = .passThrough
            } else {
                blend = .normal
            }
            let kind: Node.Kind
            if !world.isFinite {
                warn("a layer with an invalid transform")
                kind = .unsupported
            } else {
                kind = try self.kind(id, cls, world, parent)
            }
            let node = Node(classTag: cls, name: name, visible: visible, locked: locked, opacity: opacity, blend: blend, kind: kind, mask: nil, pixelMask: nil, children: [])
            return (node, world)
        }

        func kind(_ id: ObjID, _ cls: Tag, _ world: Affine, _ parent: Affine) throws(AffinityError) -> Node.Kind {
            switch cls {
            case "Scop":
                return .layer
            case "Grup":
                return .group
            case "PCrv", "ShpN", "Comp", "SNEN", "SNRR", "ShRN":
                // Current .af boards carry artboard properties (aprp) in phrp; older documents use
                // ABEn. Converted curve boards keep those properties too. Other property classes also
                // use phrp, so the field alone is not a marker.
                if s.bool(id, "ABEn") == true || s.obj(id, "phrp").map({ s.isClass($0, "aprp") }) == true {
                    if cls != "ShpN" { warn("a converted artboard outline (imported at its bounding box)") }
                    return artboard(id, world)
                }
                guard case let (local, evenOdd)? = Geometry.outline(self, id, cls, world) else {
                    warn("a \(describe(cls)) that could not be read")
                    return .unsupported
                }
                let (fills, strokes) = PaintReader.nodePaint(self, id, world)
                return .shape(path: local.transformed(world), fills: fills, strokes: strokes, evenOdd: evenOdd)
            case "TxtA", "TxtF", "TxtC":
                if let t = TextReader.read(self, id, world) { return .text(t) }
                warn("text whose story could not be read (master-page text, or an unknown layout)")
                return .unsupported
            case "ImgN", "Rstr":
                if let img = try Raster.nodeImage(self, id, world) { return .image(img) }
                return .unsupported
            case "EmbN":
                if let img = try Raster.embedded(self, id, world) {
                    warn("embedded documents and symbols (imported as pictures of them)")
                    return .image(img)
                }
                warn("embedded documents and symbols without a cached picture")
                return .unsupported
            case "FRst":
                // A fill layer paints its whole bitmap area; its gradient lives in page space.
                let bitmap = s.obj(id, "Bitm")
                func size(_ t: Tag) -> Double? {
                    bitmap.flatMap { s.int($0, t) }.map(Double.init).flatMap { $0 > 0 ? $0 : nil }
                }
                if let w = size("BmpW"), let h = size("BmpH") {
                    let local = Path(subpaths: [Shapes.rectangle(0, 0, w, h)])
                    let fills = PaintReader.fills(self, id, parent, "BFFl")
                    return .shape(path: local.transformed(world), fills: fills, strokes: [], evenOdd: false)
                }
                warn("fill layers without an area")
                return .unsupported
            default:
                warn("\(describe(cls)) layers")
                return .unsupported
            }
        }

        /// Vector shapes attached to a node (`AdCh`) mask it: it shows only inside their outlines; an
        /// attached mask layer is a pixel mask. Adjustments attached the same way are reported.
        func attachedMasks(_ id: ObjID, _ world: Affine) throws(AffinityError) -> (Path?, Image?) {
            var mask: Path?
            var pixels: Image?
            for a in s.objs(id, "AdCh") {
                let cls = s.classTag(a) ?? Tag(0)
                if s.bool(a, "Visi") == false { continue }
                if cls == "PCrv" || cls == "ShpN" || cls == "Comp" {
                    let local = (s.floats(a, "Xfrm", count: 6).map(Affine.fromXfrm) ?? .identity).then(world)
                    if case let (p, _)? = Geometry.outline(self, a, cls, local) {
                        var m = mask ?? Path()
                        m.subpaths.append(contentsOf: p.transformed(local).subpaths)
                        mask = m
                    }
                } else if cls == "MRst" {
                    let local = (s.floats(a, "Xfrm", count: 6).map(Affine.fromXfrm) ?? .identity).then(world)
                    if let m = try Raster.mask(self, a, local) {
                        if pixels == nil {
                            pixels = m
                        } else {
                            warn("several pixel masks on one layer (only the first is used)")
                        }
                    }
                } else {
                    warn("\(describe(cls)) layers attached to other layers (imported without them)")
                }
            }
            return (mask, pixels)
        }

        func artboard(_ id: ObjID, _ world: Affine) -> Node.Kind {
            let b = s.floats(id, "ShpB", count: 4).map(Affinity.rect) ?? .zero
            let corners = [Point(x: b.x0, y: b.y0), Point(x: b.x1, y: b.y0), Point(x: b.x1, y: b.y1), Point(x: b.x0, y: b.y1)].map(world.apply)
            if abs(world.b) > 1e-9 || abs(world.c) > 1e-9 || world.a <= 0 || world.d <= 0 {
                warn("a rotated or flipped artboard (imported at its bounding box)")
            }
            let rect = Rect(
                x0: corners.reduce(Double.infinity) { Double.minimum($0, $1.x) },
                y0: corners.reduce(Double.infinity) { Double.minimum($0, $1.y) },
                x1: corners.reduce(-Double.infinity) { Double.maximum($0, $1.x) },
                y1: corners.reduce(-Double.infinity) { Double.maximum($0, $1.y) }
            )
            let background = PaintReader.fills(self, id, world, "BFFl")
            return .artboard(rect: rect, background: background)
        }
    }

    /// Page rectangles: `SpMd.PagR[].rctp` (Publisher 2, Affinity 3) or `SprB` split into `PagC`
    /// equal pages (Publisher 1 facing spreads).
    static func pages(_ s: Stream, _ spread: ObjID) -> [Rect] {
        if let md = s.obj(spread, "SpMd") {
            let v = s.objs(md, "PagR").compactMap { s.floats($0, "rctp", count: 4).map(rect) }.filter { $0.x1 > $0.x0 && $0.y1 > $0.y0 }
            if !v.isEmpty { return v }
        }
        if let b = s.floats(spread, "SprB", count: 4).map(rect), let n = s.int(spread, "PagC"), (2...16).contains(n) {
            let w = (b.x1 - b.x0) / Double(n)
            return (0..<Int(n)).map { i in Rect(x0: b.x0 + w * Double(i), y0: b.y0, x1: b.x0 + w * Double(i + 1), y1: b.y1) }
        }
        return []
    }

    static func union(_ a: Rect, _ b: Rect) -> Rect {
        Rect(x0: Double.minimum(a.x0, b.x0), y0: Double.minimum(a.y0, b.y0), x1: Double.maximum(a.x1, b.x1), y1: Double.maximum(a.y1, b.y1))
    }

    static func isContainer(_ cls: Tag) -> Bool {
        cls == "Scop" || cls == "Grup"
    }

    static func rect(_ v: [Double]) -> Rect {
        Rect(x0: v[0], y0: v[1], x1: v[2], y1: v[3])
    }

    /// A readable name for a layer class in warnings.
    static func describe(_ cls: Tag) -> String {
        switch cls {
        case "PCrv": return "curve"
        case "ShpN", "SNEN", "SNRR", "ShRN": return "shape"
        case "Comp": return "compound"
        case "Rstr": return "pixel"
        case "ImgN": return "image"
        case "EmbN": return "embedded document"
        case "MPIN": return "master page instance"
        case "FRst": return "fill"
        case "MRst": return "mask"
        case "Slic", "SlcP": return "slice"
        case "3DLA": return "3D"
        default:
            let b = cls.bytes
            return b[2] == UInt8(ascii: "R") && b[3] == UInt8(ascii: "A") ? "adjustment" : "unknown"
        }
    }
}
