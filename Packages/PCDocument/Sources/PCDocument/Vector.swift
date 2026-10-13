// Vector data: paths (Pen tool), shape layers, saved/work paths and vector masks. Pure data;
// rasterization lives in the vector engine, the PSD mapping in the doc⇄PSD layer.
// Port of photocraft-doc (crates/doc/src/vector.rs), MIT OR Apache-2.0, © ArtCraft Team and the
// PhotoCraft contributors.
//
// Coordinates are document pixels (f64, y down), cubic Bézier. A subpath is a list of knots;
// segment `i` runs from `knots[i].anchor` via `knots[i].outCtrl` and `knots[i+1].inCtrl` to
// `knots[i+1].anchor` (closed subpaths add the segment back to the first knot). A knot whose
// control points equal its anchor is a corner with straight segments.
//
// Path operations follow Photoshop: every subpath is filled on its own (with the path's
// `FillRule`) and folded, in order, into the result with its `PathOp`; the first subpath always
// acts as "combine" (see `VectorPath.effectiveOp`; verified against Photoshop's pixels in the PSD
// corpus). Subpaths marked `.join` belong to the shape component before them and are filled
// together with it (a custom shape's holes). `VectorPath.inverted` inverts the final area. A
// vector mask without subpaths reveals everything (Photoshop's fresh "Add Vector Mask").

import CoreGraphics
import PCFoundation

/// A Bézier knot (anchor + two control points).
public struct Knot: Hashable, Sendable, Codable {
    public var anchor: PCPoint
    /// Control point of the segment arriving at this knot.
    public var inCtrl: PCPoint
    /// Control point of the segment leaving this knot.
    public var outCtrl: PCPoint
    /// Smooth (linked) knot: the Pen tool keeps both handles collinear.
    public var smooth: Bool

    public init(anchor: PCPoint, inCtrl: PCPoint, outCtrl: PCPoint, smooth: Bool = false) {
        self.anchor = anchor; self.inCtrl = inCtrl; self.outCtrl = outCtrl; self.smooth = smooth
    }

    /// A corner knot with retracted handles.
    public static func corner(_ x: Double, _ y: Double) -> Knot {
        let p = PCPoint(x, y)
        return Knot(anchor: p, inCtrl: p, outCtrl: p, smooth: false)
    }

    /// A smooth knot with explicit handles.
    public static func smooth(anchor: PCPoint, inCtrl: PCPoint, outCtrl: PCPoint) -> Knot {
        Knot(anchor: anchor, inCtrl: inCtrl, outCtrl: outCtrl, smooth: true)
    }

    public func transform(_ a: PCAffine) -> Knot {
        Knot(anchor: a.apply(anchor), inCtrl: a.apply(inCtrl), outCtrl: a.apply(outCtrl), smooth: smooth)
    }

    enum CodingKeys: String, CodingKey { case anchor, inCtrl = "in_ctrl", outCtrl = "out_ctrl", smooth }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        anchor = try c.decode(PCPoint.self, forKey: .anchor)
        inCtrl = try c.decode(PCPoint.self, forKey: .inCtrl)
        outCtrl = try c.decode(PCPoint.self, forKey: .outCtrl)
        smooth = try c.decode(.smooth, or: false)
    }
}

/// How a subpath combines with the subpaths before it (Photoshop's path operations).
public enum PathOp: String, CaseIterable, Hashable, Sendable, Codable {
    /// Combine shapes (union).
    case combine = "Combine"
    /// Subtract front shape.
    case subtract = "Subtract"
    /// Intersect shape areas.
    case intersect = "Intersect"
    /// Exclude overlapping shapes (xor).
    case exclude = "Exclude"
    /// Part of the previous subpath's shape component (PSD operation -1 after a component's first
    /// record): the component's subpaths are filled together, with the path's fill rule, so inner
    /// subpaths wound the other way cut holes (custom shapes).
    case join = "Join"
}

/// Winding rule used to fill each subpath.
public enum FillRule: String, CaseIterable, Hashable, Sendable, Codable {
    case nonZero = "NonZero"
    case evenOdd = "EvenOdd"

    public var cgFillRule: CGPathFillRule { self == .nonZero ? .winding : .evenOdd }
}

/// One subpath: open or closed knots and the operation folding it into the path.
public struct Subpath: Hashable, Sendable, Codable {
    public var closed: Bool
    public var knots: [Knot]
    public var op: PathOp

    public init(closed: Bool = false, knots: [Knot] = [], op: PathOp = .combine) {
        self.closed = closed; self.knots = knots; self.op = op
    }

    /// Closed polygon through `pts` (corner knots).
    public static func polygon(_ pts: [(Double, Double)]) -> Subpath {
        Subpath(closed: true, knots: pts.map { Knot.corner($0.0, $0.1) }, op: .combine)
    }

    /// Open polyline through `pts`.
    public static func polyline(_ pts: [(Double, Double)]) -> Subpath {
        var s = polygon(pts)
        s.closed = false
        return s
    }

    public func withOp(_ op: PathOp) -> Subpath {
        var s = self
        s.op = op
        return s
    }

    /// Cubic segments `[p0, c1, c2, p1]`.
    public var segments: [[PCPoint]] {
        let n = knots.count
        if n < 2 { return [] }
        let count = closed ? n : n - 1
        return (0..<count).map { i in
            let (a, b) = (knots[i], knots[(i + 1) % n])
            return [a.anchor, a.outCtrl, b.inCtrl, b.anchor]
        }
    }

    /// This subpath as a CoreGraphics path (one figure, closed when `closed`).
    public var cgPath: CGPath {
        let p = CGMutablePath()
        guard let first = knots.first else { return p }
        p.move(to: first.anchor.cgPoint)
        for s in segments { p.addCurve(to: s[3].cgPoint, control1: s[1].cgPoint, control2: s[2].cgPoint) }
        if closed { p.closeSubpath() }
        return p
    }

    enum CodingKeys: String, CodingKey { case closed, knots, op }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        closed = try c.decode(Bool.self, forKey: .closed)
        knots = try c.decode([Knot].self, forKey: .knots)
        op = try c.decode(.op, or: .combine)
    }
}

/// A vector path: subpaths plus how they are filled and combined (photocraft `vector::Path`;
/// renamed to avoid SwiftUI's `Path`).
public struct VectorPath: Hashable, Sendable, Codable {
    public var subpaths: [Subpath]
    public var fillRule: FillRule
    /// The final area is inverted (PSD vector-mask invert flag / "initial fill rule" = 1).
    public var inverted: Bool

    public init(_ subpaths: [Subpath] = [], fillRule: FillRule = .nonZero, inverted: Bool = false) {
        self.subpaths = subpaths; self.fillRule = fillRule; self.inverted = inverted
    }

    public var isEmpty: Bool { subpaths.allSatisfy { $0.knots.isEmpty } }

    /// The operation actually applied for subpath `i`: Photoshop applies the first subpath as
    /// "combine" whatever its stored operation (a lone "intersect" shape still draws).
    public func effectiveOp(_ i: Int) -> PathOp {
        i == 0 || i >= subpaths.count ? .combine : subpaths[i].op
    }

    /// Shape components: ranges of subpaths filled together (a subpath starts a new component
    /// unless it is a `.join`), each folded in with its first subpath's `effectiveOp`.
    public var components: [Range<Int>] {
        var out: [Range<Int>] = []
        for (i, s) in subpaths.enumerated() {
            if s.op == .join, let last = out.last {
                out[out.count - 1] = last.lowerBound..<(i + 1)
            } else {
                out.append(i..<(i + 1))
            }
        }
        return out
    }

    public func transform(_ a: PCAffine) -> VectorPath {
        var p = self
        for s in p.subpaths.indices {
            for k in p.subpaths[s].knots.indices { p.subpaths[s].knots[k] = p.subpaths[s].knots[k].transform(a) }
        }
        return p
    }

    /// Bounds `[x0, y0, x1, y1]` of all anchors and control points (a superset of the curve); nil
    /// without knots.
    public var controlBounds: SIMD4<Double>? {
        var out: SIMD4<Double>?
        for s in subpaths {
            for k in s.knots {
                for p in [k.anchor, k.inCtrl, k.outCtrl] {
                    if let b = out {
                        out = SIMD4(Double.minimum(b.x, p.x), Double.minimum(b.y, p.y), Double.maximum(b.z, p.x), Double.maximum(b.w, p.y))
                    } else {
                        out = SIMD4(p.x, p.y, p.x, p.y)
                    }
                }
            }
        }
        return out
    }

    enum CodingKeys: String, CodingKey { case subpaths, fillRule = "fill_rule", inverted }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        subpaths = try c.decode([Subpath].self, forKey: .subpaths)
        fillRule = try c.decode(.fillRule, or: .nonZero)
        inverted = try c.decode(.inverted, or: false)
    }
}

/// A document-level path (Paths panel entry).
public struct NamedPath: Hashable, Sendable {
    public var name: String
    public var path: VectorPath
    /// Original PSD path resource data; reused on export while it still decodes to `path`.
    public var psdRaw: [UInt8]?

    public init(name: String = "", path: VectorPath = VectorPath(), psdRaw: [UInt8]? = nil) {
        self.name = name; self.path = path; self.psdRaw = psdRaw
    }
}

/// The document's clipping path (PSD resource 2999): which saved path clips on export.
public struct ClippingPath: Hashable, Sendable, Codable {
    public var name: String
    /// Output flatness in device pixels (0 = printer default).
    public var flatness: Float

    public init(name: String = "", flatness: Float = 0) { self.name = name; self.flatness = flatness }
}

/// A layer's vector mask (Layer › Vector Mask).
public struct VectorMask: Hashable, Sendable, Codable {
    public var path: VectorPath
    public var enabled: Bool
    /// Moves with the layer.
    public var linked: Bool
    /// Density 0...1 (Properties panel), like `LayerMask.density`.
    public var density: Float
    /// Feather radius in px (stored; rendered unfeathered for now).
    public var feather: Float

    public init(path: VectorPath, enabled: Bool = true, linked: Bool = true, density: Float = 1, feather: Float = 0) {
        self.path = path; self.enabled = enabled; self.linked = linked; self.density = density; self.feather = feather
    }
}

/// Where a stroke sits relative to the path.
public enum StrokeAlign: String, CaseIterable, Hashable, Sendable, Codable {
    case inside = "Inside"
    case center = "Center"
    case outside = "Outside"
}

public enum LineCap: String, CaseIterable, Hashable, Sendable, Codable {
    case butt = "Butt"
    case round = "Round"
    case square = "Square"

    public var cgLineCap: CGLineCap {
        switch self { case .butt: .butt; case .round: .round; case .square: .square }
    }
}

public enum LineJoin: String, CaseIterable, Hashable, Sendable, Codable {
    case miter = "Miter"
    case round = "Round"
    case bevel = "Bevel"

    public var cgLineJoin: CGLineJoin {
        switch self { case .miter: .miter; case .round: .round; case .bevel: .bevel }
    }
}

/// Shape stroke (Photoshop's shape "Stroke" options, not the layer-style stroke). Every JSON key
/// is optional.
public struct ShapeStroke: Hashable, Sendable, Codable {
    /// Width in px.
    public var width: Float = 3
    public var paint: Fill = .solid(.black)
    public var opacity: Float = 1
    public var align: StrokeAlign = .center
    public var cap: LineCap = .butt
    public var join: LineJoin = .miter
    /// Miter limit as a multiple of the width (Photoshop default 100 → effectively always mitered;
    /// SVG-style 4 is common elsewhere).
    public var miterLimit: Float = 100
    /// Dash pattern in multiples of the stroke width (Photoshop's convention); empty = solid.
    public var dashes: [Float] = []
    /// Dash offset in multiples of the width.
    public var dashOffset: Float = 0

    public init(width: Float = 3, paint: Fill = .solid(.black), opacity: Float = 1, align: StrokeAlign = .center, cap: LineCap = .butt,
                join: LineJoin = .miter, miterLimit: Float = 100, dashes: [Float] = [], dashOffset: Float = 0) {
        self.width = width; self.paint = paint; self.opacity = opacity; self.align = align; self.cap = cap
        self.join = join; self.miterLimit = miterLimit; self.dashes = dashes; self.dashOffset = dashOffset
    }

    /// Limits accepted by interactive commands. Importers retain original descriptor data;
    /// renderers must additionally bound their work for arbitrary file-provided geometry.
    public func validate() throws(DocumentError) {
        if !width.isFinite || !(0...1_000_000).contains(width) {
            throw DocumentError("stroke width must be finite and between 0 and 1000000 px")
        }
        if !opacity.isFinite || !(0...1).contains(opacity) {
            throw DocumentError("stroke opacity must be between 0 and 100%")
        }
        if !miterLimit.isFinite || !(1...500).contains(miterLimit) {
            throw DocumentError("miter limit must be between 1 and 500")
        }
        if !dashOffset.isFinite || abs(dashOffset) > 1_000_000 {
            throw DocumentError("dash offset must be finite and within ±1000000 widths")
        }
        if dashes.count > 32 || dashes.contains(where: { !$0.isFinite || !(0...10000).contains($0) }) {
            throw DocumentError("dash pattern must contain at most 32 finite lengths between 0 and 10000 widths")
        }
        if !dashes.isEmpty && dashes.reduce(0, +) < 0.01 {
            throw DocumentError("dash pattern total must be at least 0.01 widths")
        }
    }

    enum CodingKeys: String, CodingKey {
        case width, paint, opacity, align, cap, join, miterLimit = "miter_limit", dashes, dashOffset = "dash_offset"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ShapeStroke()
        width = try c.decode(.width, or: d.width)
        paint = try c.decode(.paint, or: d.paint)
        opacity = try c.decode(.opacity, or: d.opacity)
        align = try c.decode(.align, or: d.align)
        cap = try c.decode(.cap, or: d.cap)
        join = try c.decode(.join, or: d.join)
        miterLimit = try c.decode(.miterLimit, or: d.miterLimit)
        dashes = try c.decode(.dashes, or: d.dashes)
        dashOffset = try c.decode(.dashOffset, or: d.dashOffset)
    }
}

/// Parametric ("live") shape the path was generated from, kept for re-editing (Properties panel).
/// JSON: internally tagged by `"kind"` (`{"kind":"rect","rect":[…],"radii":[…]}`).
public enum LiveShape: Hashable, Sendable, Codable {
    /// Rectangle `[x, y, w, h]` with corner radii `[tl, tr, br, bl]` (all zero = sharp).
    case rect(rect: SIMD4<Double>, radii: SIMD4<Double>)
    case ellipse(rect: SIMD4<Double>)
    /// Regular polygon or star inscribed in `rect`; `starRatio` = inner/outer radius (1 = polygon).
    case polygon(rect: SIMD4<Double>, sides: UInt32, starRatio: Double)
    /// Line from `from` to `to` drawn as a filled bar `weight` px thick.
    case line(from: SIMD2<Double>, to: SIMD2<Double>, weight: Double)

    enum CodingKeys: String, CodingKey { case kind, rect, radii, sides, starRatio = "star_ratio", from, to, weight }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "rect": self = .rect(rect: try c.decode(SIMD4<Double>.self, forKey: .rect), radii: try c.decode(SIMD4<Double>.self, forKey: .radii))
        case "ellipse": self = .ellipse(rect: try c.decode(SIMD4<Double>.self, forKey: .rect))
        case "polygon":
            self = .polygon(rect: try c.decode(SIMD4<Double>.self, forKey: .rect), sides: try c.decode(UInt32.self, forKey: .sides),
                            starRatio: try c.decode(Double.self, forKey: .starRatio))
        case "line":
            self = .line(from: try c.decode(SIMD2<Double>.self, forKey: .from), to: try c.decode(SIMD2<Double>.self, forKey: .to),
                         weight: try c.decode(Double.self, forKey: .weight))
        default: throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "unknown live shape \(kind)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .rect(let rect, let radii):
            try c.encode("rect", forKey: .kind); try c.encode(rect, forKey: .rect); try c.encode(radii, forKey: .radii)
        case .ellipse(let rect):
            try c.encode("ellipse", forKey: .kind); try c.encode(rect, forKey: .rect)
        case .polygon(let rect, let sides, let ratio):
            try c.encode("polygon", forKey: .kind); try c.encode(rect, forKey: .rect)
            try c.encode(sides, forKey: .sides); try c.encode(ratio, forKey: .starRatio)
        case .line(let from, let to, let weight):
            try c.encode("line", forKey: .kind); try c.encode(from, forKey: .from)
            try c.encode(to, forKey: .to); try c.encode(weight, forKey: .weight)
        }
    }
}

/// A shape layer: a filled and/or stroked path.
public struct ShapeLayer: Equatable, Sendable {
    public var path: VectorPath
    /// nil = no fill (Photoshop's fill "none").
    public var fill: Fill?
    public var stroke: ShapeStroke?
    public var live: LiveShape?
    /// Rasterized appearance (from PSD or the vector engine).
    public var cache: Surface?
    /// Data of the PSD vector mask block (`vsms`, else `vmsk`). On export it replaces that entry in
    /// `Layer.psdBlocks` while it still decodes to `path`.
    public var psdRaw: [UInt8]?

    public init(path: VectorPath = VectorPath(), fill: Fill? = nil, stroke: ShapeStroke? = nil, live: LiveShape? = nil,
                cache: Surface? = nil, psdRaw: [UInt8]? = nil) {
        self.path = path; self.fill = fill; self.stroke = stroke; self.live = live; self.cache = cache; self.psdRaw = psdRaw
    }
}
