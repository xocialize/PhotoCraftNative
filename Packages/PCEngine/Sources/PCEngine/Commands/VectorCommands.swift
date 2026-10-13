// Port of photocraft-engine (crates/engine/src/vector_cmds.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Vector commands: shape layers (`shape.*`), document paths (`path.*`, the Paths panel), selection
// ⇄ path, Fill / Stroke Path, layer vector masks (`layer.vectorMask.*`), Combine Shapes, the
// clipping path and the shape fill / stroke clipboard. Coordinates are document pixels. Paths in
// params and results use photocraft's compact JSON form (`parsePath` / `pathJSON`), which also
// accepts PCDocument's serde-shaped `VectorPath` encoding. Rendering is PCPlatform's CoreGraphics
// engine (`VectorRasterizer`); the pure path geometry CoreGraphics doesn't cover (flattening,
// tracing, non-affine maps, point edits) is in `VectorCommands+Geometry.swift`. Every edit re-renders
// the shape layer's cache in one undoable step.

import CoreGraphics
import Foundation
import PCDocument
import PCFoundation
import PCPaint
import PCPlatform
import PCRender
import simd

enum VectorCommands: CommandModule {
    static let name = "vector_cmds"
    static let m = "vector_cmds"

    /// Keys PSD uses for a shape layer's vector data; dropped when a shape is rasterized.
    static let shapeBlocks: [PSDKey] = ["vmsk", "vsms", "vogk", "vstk", "vscg", "SoCo", "GdFl", "PtFl"]

    /// The shape fill / stroke clipboard (photocraft `Session::path_fill_clipboard`,
    /// `path_stroke_clipboard`).
    struct StyleClipboard: Sendable {
        var fill: Fill?
        var stroke: ShapeStroke?
    }

    enum StyleClipboardKey: StateKey { static let defaultValue = StyleClipboard() }

    // MARK: - Preconditions

    static let hasDoc: CommandEnabled = { s, _ in s.active == nil ? "no document open" : nil }
    static let hasLayer: CommandEnabled = Pre.hasLayer
    static let hasSelection: CommandEnabled = { s, _ in s.active?.doc.selection == nil ? "no selection" : nil }

    static func activeShape(_ s: Session) -> Result<ShapeLayer, EngineError> {
        guard let d = s.active else { return .failure(.other("no document open")) }
        guard let id = d.activeLayer, let l = d.doc.layer(id) else { return .failure(.other("no active layer")) }
        guard case .shape(let sh) = l.content else { return .failure(.other("active layer is not a shape layer")) }
        return .success(sh)
    }

    static func reason(_ r: Result<ShapeLayer, EngineError>) -> String? {
        if case .failure(let e) = r { return e.description }
        return nil
    }

    static let hasShapeFill: CommandEnabled = { s, _ in
        switch activeShape(s) {
        case .failure(let e): return e.description
        case .success(let sh): return sh.fill == nil ? "shape has no fill" : nil
        }
    }

    static let hasShapeStroke: CommandEnabled = { s, _ in
        switch activeShape(s) {
        case .failure(let e): return e.description
        case .success(let sh): return sh.stroke == nil ? "shape has no stroke" : nil
        }
    }

    static let canPasteShapeFill: CommandEnabled = { s, _ in
        reason(activeShape(s)) ?? (s.state[StyleClipboardKey.self].fill == nil ? "no shape fill copied" : nil)
    }

    static let canPasteShapeStroke: CommandEnabled = { s, _ in
        reason(activeShape(s)) ?? (s.state[StyleClipboardKey.self].stroke == nil ? "no shape stroke copied" : nil)
    }

    // MARK: - Shape style clipboard

    static func copyShapeFill(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let sh = try activeShape(s).get()
        guard let fill = sh.fill else { throw EngineError.other("shape has no fill") }
        s.state[StyleClipboardKey.self].fill = fill
        return .null
    }

    static func copyShapeStroke(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let sh = try activeShape(s).get()
        guard let stroke = sh.stroke else { throw EngineError.other("shape has no stroke") }
        s.state[StyleClipboardKey.self].stroke = stroke
        return .null
    }

    static func pasteShapeFill(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        guard let fill = s.state[StyleClipboardKey.self].fill else { throw EngineError.other("no shape fill copied") }
        let id = try s.layerParam(p)
        try withShape(s, id, "Paste Fill") { sh, _ in sh.fill = fill }
        return try shapeInfo(s, id)
    }

    static func pasteShapeStroke(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        guard let stroke = s.state[StyleClipboardKey.self].stroke else { throw EngineError.other("no shape stroke copied") }
        let id = try s.layerParam(p)
        try withShape(s, id, "Paste Complete Stroke") { sh, _ in sh.stroke = stroke }
        return try shapeInfo(s, id)
    }

    // MARK: - JSON helpers

    static func f64(_ p: JSONValue, _ k: String) -> Double? { p[k]?.doubleValue }

    /// `[x, y]` or `{"x":…,"y":…}` (photocraft `pt`).
    static func pt(_ v: JSONValue?) -> PCPoint? {
        guard let v else { return nil }
        switch v {
        case .array(let a) where a.count >= 2:
            guard let x = a[0].doubleValue, let y = a[1].doubleValue else { return nil }
            return PCPoint(x, y)
        case .object:
            guard let x = v["x"]?.doubleValue, let y = v["y"]?.doubleValue else { return nil }
            return PCPoint(x, y)
        default:
            return nil
        }
    }

    /// The first `n` numbers of the array at `k` (photocraft `nums::<N>`).
    static func nums(_ p: JSONValue, _ k: String, _ n: Int) -> [Double]? {
        guard let a = p[k]?.arrayValue, a.count >= n else { return nil }
        var out: [Double] = []
        for v in a.prefix(n) {
            guard let x = v.doubleValue else { return nil }
            out.append(x)
        }
        return out
    }

    static func simd4(_ a: [Double]) -> SIMD4<Double> { SIMD4(a[0], a[1], a[2], a[3]) }

    /// `[tl, tr, br, bl]` from an array or a single number.
    static func radii(_ p: JSONValue) -> SIMD4<Double>? {
        guard let v = p["radii"] ?? p["radius"] else { return nil }
        if case .number(let r) = v { return SIMD4(repeating: r) }
        return nums(p, "radii", 4).map(simd4)
    }

    /// `"#rrggbb"`, `"#rrggbbaa"` or `[r,g,b(,a)]` (photocraft `vector_cmds::color`).
    static func color(_ v: JSONValue?) -> PCColor? {
        guard let v else { return nil }
        switch v {
        case .array(let a) where a.count >= 3:
            let c = a.map { Float($0.doubleValue ?? 0) }
            return .rgb(c[0], c[1], c[2], c.count > 3 ? c[3] : 1)
        case .string(let s0):
            let s = Array(String(s0.drop { $0 == "#" }).utf8)
            func h(_ i: Int) -> Float? {
                guard i + 2 <= s.count, let v = UInt8(String(decoding: s[i..<i + 2], as: UTF8.self), radix: 16) else { return nil }
                return Float(v) / 255
            }
            switch s.count {
            case 6:
                guard let r = h(0), let g = h(2), let b = h(4) else { return nil }
                return .rgb(r, g, b)
            case 8:
                guard let r = h(0), let g = h(2), let b = h(4), let a = h(6) else { return nil }
                return .rgb(r, g, b, a)
            default:
                return nil
            }
        default:
            return nil
        }
    }

    static func hex(_ c: PCColor) -> String {
        let rgb = c.rgb
        func q(_ v: Float) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        if c.alpha < 1 { return String(format: "#%02x%02x%02x%02x", q(rgb.x), q(rgb.y), q(rgb.z), q(c.alpha)) }
        return String(format: "#%02x%02x%02x", q(rgb.x), q(rgb.y), q(rgb.z))
    }

    static func opFrom(_ s: String) -> PathOp? {
        switch s.lowercased() {
        case "combine", "add", "union": .combine
        case "subtract", "minus": .subtract
        case "intersect": .intersect
        case "exclude", "xor": .exclude
        case "join": .join
        default: nil
        }
    }

    static func opName(_ op: PathOp) -> String { op.rawValue.lowercased() }

    /// Parses a path from the compact JSON form (or the serde form) (photocraft `parse_path`).
    static func parsePath(_ v: JSONValue) throws(GeometryError) -> VectorPath {
        guard let subs = v["subpaths"]?.arrayValue else { throw GeometryError(message: "path needs `subpaths`") }
        var out: [Subpath] = []
        out.reserveCapacity(subs.count)
        for (i, s) in subs.enumerated() {
            guard let knotsV = s["knots"]?.arrayValue else { throw GeometryError(message: "subpath \(i) needs `knots`") }
            var knots: [Knot] = []
            knots.reserveCapacity(knotsV.count)
            for (j, k) in knotsV.enumerated() {
                if case .array = k {
                    guard let a = pt(k) else { throw GeometryError(message: "knot \(i).\(j): expected [x, y]") }
                    knots.append(.corner(a.x, a.y))
                } else {
                    guard let a = pt(k["anchor"]) else { throw GeometryError(message: "knot \(i).\(j): missing anchor") }
                    func get(_ keys: [String]) -> PCPoint? { keys.lazy.compactMap { pt(k[$0]) }.first }
                    knots.append(Knot(anchor: a, inCtrl: get(["in", "inCtrl", "in_ctrl"]) ?? a, outCtrl: get(["out", "outCtrl", "out_ctrl"]) ?? a,
                                      smooth: k["smooth"]?.boolValue ?? false))
                }
            }
            let op: PathOp
            if let o = s["op"]?.stringValue {
                guard let x = opFrom(o) else { throw GeometryError(message: "subpath \(i): unknown op `\(o)`") }
                op = x
            } else {
                op = .combine
            }
            out.append(Subpath(closed: s["closed"]?.boolValue ?? true, knots: knots, op: op))
        }
        let rule: FillRule
        switch (v["fillRule"] ?? v["fill_rule"])?.stringValue?.lowercased() {
        case "evenodd", "even-odd", "even_odd": rule = .evenOdd
        default: rule = .nonZero
        }
        return VectorPath(out, fillRule: rule, inverted: v["inverted"]?.boolValue ?? false)
    }

    /// `parsePath` for a command: failures are bad params of `cmd`.
    static func parsePath(_ cmd: String, _ v: JSONValue) throws -> VectorPath {
        do { return try parsePath(v) } catch { throw bad(cmd, error) }
    }

    /// A geometry failure as a bad-params error of `cmd` (other errors pass through).
    static func bad(_ cmd: String, _ e: any Error) -> EngineError {
        if let g = e as? GeometryError { return .bad(cmd, g.message) }
        return .wrap(e)
    }

    /// The compact JSON form of a path (photocraft `path_json`).
    static func pathJSON(_ p: VectorPath) -> JSONValue {
        func a(_ q: PCPoint) -> JSONValue { [.number(q.x), .number(q.y)] }
        return [
            "subpaths": .array(p.subpaths.map { s in
                [
                    "closed": .bool(s.closed), "op": .string(opName(s.op)),
                    "knots": .array(s.knots.map { k in ["anchor": a(k.anchor), "in": a(k.inCtrl), "out": a(k.outCtrl), "smooth": .bool(k.smooth)] }),
                ]
            }),
            "fillRule": .string(p.fillRule == .evenOdd ? "evenodd" : "nonzero"),
            "inverted": .bool(p.inverted),
        ]
    }

    static func fillJSON(_ f: Fill) -> JSONValue {
        switch f {
        case .solid(let c):
            return .string(hex(c))
        case .gradient(let g):
            return ["gradient": [
                "stops": .array(g.stops.map { [.float($0.location), .string(hex($0.color))] }),
                "angle": .float(g.angle), "scale": .float(g.scale * 100), "style": .string(g.style.rawValue.lowercased()), "reverse": .bool(g.reverse),
            ]]
        case .pattern(let p):
            return ["pattern": .string(p.name), "scale": .float(p.scale * 100)]
        }
    }

    /// `"#rrggbb"` / `[r,g,b,a]` / `{"gradient":{…}}` / `{"pattern":name,"scale"}`; `null` → no fill.
    static func parseFill(_ v: JSONValue) throws(GeometryError) -> Fill? {
        if v == .null { return nil }
        if let c = color(v) { return .solid(c) }
        if let g = v["gradient"] {
            let stops: [ColorStop]
            if let a = g["stops"]?.arrayValue {
                stops = a.compactMap { s in
                    guard let t = s[0]?.doubleValue, let c = color(s[1]) else { return nil }
                    return ColorStop(Float(t), c)
                }
            } else {
                stops = [ColorStop(0, .black), ColorStop(1, .white)]
            }
            let style: GradientStyle
            switch g["style"]?.stringValue ?? "linear" {
            case "radial": style = .radial
            case "angle": style = .angle
            case "reflected": style = .reflected
            case "diamond": style = .diamond
            default: style = .linear
            }
            return .gradient(GradientFill(stops: stops, angle: Float(f64(g, "angle") ?? 90), scale: Float(f64(g, "scale") ?? 100) / 100,
                                          style: style, reverse: g["reverse"]?.boolValue ?? false))
        }
        if let name = v["pattern"]?.stringValue {
            return .pattern(PatternFill(name: name, scale: Float(f64(v, "scale") ?? 100) / 100, id: "", angle: 0, link: true, phase: .zero))
        }
        throw GeometryError(message: "unrecognised fill \(v.serialized())")
    }

    static func strokeJSON(_ s: ShapeStroke) -> JSONValue {
        [
            "width": .float(s.width), "fill": fillJSON(s.paint), "opacity": .float(s.opacity * 100),
            "align": .string(s.align.rawValue.lowercased()), "cap": .string(s.cap.rawValue.lowercased()),
            "join": .string(s.join.rawValue.lowercased()), "miterLimit": .float(s.miterLimit), "dashes": .floats(s.dashes),
            "dashOffset": .float(s.dashOffset),
        ]
    }

    /// Applies stroke keys onto `base` (`null` / `false` → no stroke) (photocraft `parse_stroke`).
    static func parseStroke(_ v: JSONValue, base: ShapeStroke?, fg: PCColor) throws(GeometryError) -> ShapeStroke? {
        if v == .null || v.boolValue == false { return nil }
        guard v.objectValue != nil else { throw GeometryError(message: "stroke must be an object or null") }
        for (key, lo, hi, text) in [("width", 0.0, 1_000_000.0, "0 and 1000000"), ("opacity", 0, 100, "0 and 100"), ("miterLimit", 1, 500, "1 and 500"),
                                    ("dashOffset", -1_000_000, 1_000_000, "-1000000 and 1000000")] {
            if let value = v[key], !(value.doubleValue.map { $0.isFinite && $0 >= lo && $0 <= hi } ?? false) {
                throw GeometryError(message: "`\(key)` must be a finite number between \(text)")
            }
        }
        for key in ["align", "cap", "join"] where v[key] != nil && v[key]?.stringValue == nil {
            throw GeometryError(message: "`\(key)` must be a string")
        }
        var s = base ?? ShapeStroke(paint: .solid(fg))
        if let w = f64(v, "width") { s.width = Float(w) }
        if let c = v["color"] ?? v["fill"] {
            guard let f = try parseFill(c) else { throw GeometryError(message: "stroke colour cannot be null") }
            s.paint = f
        }
        if let o = f64(v, "opacity") { s.opacity = Float(o / 100) }
        if let a = v["align"]?.stringValue {
            switch a {
            case "inside": s.align = .inside
            case "outside": s.align = .outside
            case "center", "centre": s.align = .center
            default: throw GeometryError(message: "unknown align `\(a)`")
            }
        }
        if let c = v["cap"]?.stringValue {
            switch c {
            case "butt": s.cap = .butt
            case "round": s.cap = .round
            case "square": s.cap = .square
            default: throw GeometryError(message: "unknown cap `\(c)`")
            }
        }
        if let j = v["join"]?.stringValue {
            switch j {
            case "miter": s.join = .miter
            case "round": s.join = .round
            case "bevel": s.join = .bevel
            default: throw GeometryError(message: "unknown join `\(j)`")
            }
        }
        if let ml = f64(v, "miterLimit") { s.miterLimit = Float(ml) }
        if let d = v["dashes"] {
            switch d {
            case .null:
                s.dashes = []
            case .array(let a) where a.count <= 32:
                var out: [Float] = []
                for x in a {
                    guard let n = x.doubleValue, n.isFinite, n >= 0, n <= 10000 else {
                        throw GeometryError(message: "dash lengths must be finite numbers between 0 and 10000 widths")
                    }
                    out.append(Float(n))
                }
                s.dashes = out
            default:
                throw GeometryError(message: "`dashes` must be an array (multiples of the width)")
            }
        }
        if let o = f64(v, "dashOffset") { s.dashOffset = Float(o) }
        if case .failure(let e) = Result(catching: { () throws(DocumentError) in try s.validate() }) { throw GeometryError(message: e.message) }
        return s
    }

    static func liveJSON(_ l: LiveShape) -> JSONValue { .encoded(l) }

    /// Builds a live shape from `kind` + geometry params (photocraft `live_from_params`).
    static func liveFromParams(_ cmd: String, _ kind: String, _ p: JSONValue, _ prev: LiveShape?) throws -> LiveShape {
        var prevRect: SIMD4<Double>?
        switch prev {
        case .rect(let r, _)?, .ellipse(let r)?, .polygon(let r, _, _)?: prevRect = r
        default: prevRect = nil
        }
        func rect() throws -> SIMD4<Double> {
            if let r = nums(p, "rect", 4) { return simd4(r) }
            if let r = prevRect { return r }
            throw EngineError.bad(cmd, "`rect`: [x, y, w, h] is required")
        }
        switch kind {
        case "rect", "rectangle":
            var r = SIMD4<Double>(repeating: 0)
            if case .rect(_, let radii)? = prev { r = radii }
            return .rect(rect: try rect(), radii: radii(p) ?? r)
        case "roundedRect", "roundRect":
            var r = SIMD4<Double>(repeating: 10)
            if case .rect(_, let radii)? = prev, (0..<4).contains(where: { radii[$0] > 0 }) { r = radii }
            return .rect(rect: try rect(), radii: radii(p) ?? r)
        case "ellipse":
            return .ellipse(rect: try rect())
        case "polygon", "star":
            var (ps, pr): (UInt32, Double) = (5, kind == "star" ? 0.5 : 1)
            if case .polygon(_, let sides, let ratio)? = prev { (ps, pr) = (sides, ratio) }
            let sides = f64(p, "sides").map { UInt32(min(max($0.rounded(), 3), 100)) } ?? ps
            let ratio = f64(p, "starRatio").map { min(max($0, 0.01), 1) } ?? (kind == "star" && pr >= 1 ? 0.5 : pr)
            return .polygon(rect: try rect(), sides: sides, starRatio: kind == "polygon" && f64(p, "starRatio") == nil ? 1 : ratio)
        case "line":
            var (pf, pto, pw): (SIMD2<Double>?, SIMD2<Double>?, Double) = (nil, nil, 1)
            if case .line(let from, let to, let weight)? = prev { (pf, pto, pw) = (from, to, weight) }
            guard let from = nums(p, "from", 2).map({ SIMD2($0[0], $0[1]) }) ?? pf else { throw EngineError.bad(cmd, "`from`: [x, y] is required") }
            guard let to = nums(p, "to", 2).map({ SIMD2($0[0], $0[1]) }) ?? pto else { throw EngineError.bad(cmd, "`to`: [x, y] is required") }
            return .line(from: from, to: to, weight: max(f64(p, "weight") ?? pw, 0))
        default:
            throw EngineError.bad(cmd, "unknown kind `\(kind)`")
        }
    }

    /// The path `shape.create` draws for live-shape params `p` (the Shape tools preview it).
    static func shapePath(_ p: JSONValue) throws -> VectorPath {
        try liveFromParams("shape.create", p["kind"]?.stringValue ?? "rect", p, nil).path
    }

    static func liveKind(_ l: LiveShape) -> String {
        switch l {
        case .rect(_, let radii): (0..<4).contains(where: { radii[$0] > 0 }) ? "roundedRect" : "rect"
        case .ellipse: "ellipse"
        case .polygon(_, _, let ratio): ratio < 1 ? "star" : "polygon"
        case .line: "line"
        }
    }

    // MARK: - Shape geometry shared with other modules

    /// Re-renders a shape layer's cache for `doc` (canvas-clipped, the document's pixel format).
    static func refreshShape(_ doc: Document, _ sh: inout ShapeLayer) {
        sh.cache = VectorRasterizer.rasterize(sh, format: doc.pixelFormat, clip: doc.bounds)
    }

    /// A staged stroke edit rendered with `shape.edit`'s validation and cache refresh; the session
    /// and its history are untouched.
    static func previewShapeStroke(_ doc: Document, _ id: LayerId, _ params: JSONValue) throws -> Document {
        var result = doc
        let r: Void? = try result.updateLayer(id) { l in
            guard case .shape(var sh) = l.content else { throw EngineError.other("preview target is not a shape layer") }
            do { sh.stroke = try parseStroke(params, base: sh.stroke, fg: .black) } catch { throw bad("shape.edit", error) }
            if let e = validateShape(sh.path, sh.stroke) { throw EngineError.bad("shape.edit", e) }
            refreshShape(doc, &sh)
            l.content = .shape(sh)
        }
        if r == nil { throw EngineError.noLayer(id) }
        return result
    }

    /// Moves a layer's vector content by `(dx, dy)`: shape paths (re-rendered) and linked vector
    /// masks, recursing into groups (photocraft `translate_vectors`).
    static func translateVectors(_ doc: Document, _ l: inout Layer, _ dx: Double, _ dy: Double) {
        let a = PCAffine.translate(dx, dy)
        if var vm = l.vectorMask, vm.linked {
            vm.path = vm.path.transform(a)
            l.vectorMask = vm
        }
        switch l.content {
        case .shape:
            l.withShape { sh in
                transformShape(&sh, a)
                refreshShape(doc, &sh)
            }
        case .group:
            l.withChildren { cs in for i in cs.indices { translateVectors(doc, &cs[i], dx, dy) } }
        default:
            break
        }
    }

    /// Applies an affine transform to a shape's path, keeping the live shape for a translation plus
    /// axis-aligned scale, and for flips / 90° turns of rectangles, ellipses and lines (photocraft
    /// `transform_shape`).
    static func transformShape(_ sh: inout ShapeLayer, _ a: PCAffine) {
        sh.path = sh.path.transform(a)
        let (m0, m1, m2, m3, tx, ty) = (a.a, a.b, a.c, a.d, a.e, a.f)
        let axisAligned = abs(m1) < 1e-12 && abs(m2) < 1e-12 && m0 > 0 && m3 > 0
        let live = sh.live
        sh.live = nil
        if let l = live, axisAligned {
            func r(_ r: SIMD4<Double>) -> SIMD4<Double> { SIMD4(r.x * m0 + tx, r.y * m3 + ty, r.z * m0, r.w * m3) }
            func pt(_ p: SIMD2<Double>) -> SIMD2<Double> { SIMD2(p.x * m0 + tx, p.y * m3 + ty) }
            switch l {
            case .rect(let rect, let radii):
                sh.live = .rect(rect: r(rect), radii: radii * min(m0, m3))
            case .ellipse(let rect):
                sh.live = .ellipse(rect: r(rect))
            case .polygon(let rect, let sides, let ratio):
                sh.live = .polygon(rect: r(rect), sides: sides, starRatio: ratio)
            case .line(let from, let to, let weight):
                // A line's width scales perpendicular to its direction (#3063).
                let dx = to.x - from.x, dy = to.y - from.y
                let oldLength = hypot(dx, dy), newLength = hypot(dx * m0, dy * m3)
                let widthScale = oldLength > 0 && newLength > 0 ? m0 * m3 * oldLength / newLength : min(m0, m3)
                sh.live = .line(from: pt(from), to: pt(to), weight: weight * widthScale)
            }
        } else if let l = live, (abs(m1) < 1e-12 && abs(m2) < 1e-12) || (abs(m0) < 1e-12 && abs(m3) < 1e-12) {
            // Flips and 90° turns keep rectangles, ellipses and lines live (Image Rotation).
            func pt(_ p: SIMD2<Double>) -> SIMD2<Double> { SIMD2(m0 * p.x + m2 * p.y + tx, m1 * p.x + m3 * p.y + ty) }
            func r(_ r: SIMD4<Double>) -> SIMD4<Double> {
                let p = pt(SIMD2(r.x, r.y)), q = pt(SIMD2(r.x + r.z, r.y + r.w))
                return SIMD4(min(p.x, q.x), min(p.y, q.y), abs(q.x - p.x), abs(q.y - p.y))
            }
            let k = min(abs(m0) + abs(m1), abs(m2) + abs(m3))
            switch l {
            case .rect(let rect, let radii) where (0..<4).allSatisfy({ abs(radii[$0] - radii[0]) < 1e-9 }):
                sh.live = .rect(rect: r(rect), radii: radii * k)
            case .ellipse(let rect):
                sh.live = .ellipse(rect: r(rect))
            case .line(let from, let to, let weight):
                sh.live = .line(from: pt(from), to: pt(to), weight: weight * k)
            default:
                sh.live = nil
            }
        }
        sh.psdRaw = nil
    }

    /// Is every anchor and control point of `path` finite?
    static func finitePath(_ path: VectorPath) -> Bool {
        path.subpaths.allSatisfy { $0.knots.allSatisfy { k in [k.anchor, k.inCtrl, k.outCtrl].allSatisfy { $0.x.isFinite && $0.y.isFinite } } }
    }

    /// `path` through Distort / Perspective (`h`) or Warp (`warp`); refused when the map sends a
    /// point to infinity (photocraft `map_path`).
    static func mapPath(_ path: VectorPath, homography h: Homography?, warp: Warp?) throws -> VectorPath {
        let out: VectorPath
        if let w = warp {
            out = mapPath(path, { p in PCPoint(w.map(p.x, p.y)) }, tol: 0.1)
        } else if let h {
            out = mapPoints(path) { p in PCPoint(h.apply(p.x, p.y)) }
        } else {
            out = path
        }
        if !finitePath(out) { throw EngineError.other("the distortion sends part of the path out of bounds") }
        return out
    }

    /// Distort, Perspective or Warp of a shape layer: the path is mapped and the shape stops being
    /// live (photocraft `map_shape`).
    static func mapShape(_ sh: inout ShapeLayer, homography h: Homography?, warp: Warp?) throws {
        sh.path = try mapPath(sh.path, homography: h, warp: warp)
        sh.live = nil
        sh.psdRaw = nil
    }

    // MARK: - Shape layers

    static func notShape(_ id: LayerId, _ l: Layer) -> String {
        "layer \(id.rawValue) is \(l.content.article) \(l.content.kindName) layer, not a shape layer"
    }

    static func shapeInfo(_ s: Session, _ id: LayerId) throws -> JSONValue {
        guard let d = s.active else { throw EngineError.noDocument }
        guard let l = d.doc.layer(id) else { throw EngineError.noLayer(id) }
        guard case .shape(let sh) = l.content else { throw EngineError.other(notShape(id, l)) }
        let bounds = sh.cache.map(\.contentBounds).flatMap { $0.isEmpty ? nil : JSONValue.rect($0) }
        return [
            "layer": .id(id), "name": .string(l.name), "path": pathJSON(sh.path),
            "fill": sh.fill.map(fillJSON) ?? .null, "stroke": sh.stroke.map(strokeJSON) ?? .null,
            "live": sh.live.map(liveJSON) ?? .null, "kind": .string(sh.live.map(liveKind) ?? "path"),
            "bounds": bounds ?? .null,
        ]
    }

    /// Runs `f` on shape layer `id` in one undoable step and re-renders it (photocraft `with_shape`).
    @discardableResult
    static func withShape<R>(_ s: Session, _ id: LayerId, _ label: String, _ f: (inout ShapeLayer, inout Layer) throws -> R) throws -> R {
        if let st = s.active {
            let locks = st.doc.effectiveLocks(id)
            if locks.all || locks.pixels { throw EngineError.other("shape layer is locked") }
        }
        return try s.edit(label) { doc, _ in
            let snapshot = doc
            guard let r = try doc.updateLayer(id, { l -> R in
                guard case .shape(var sh) = l.content else { throw EngineError.other(notShape(id, l)) }
                l.content = .fill(.solid(.black))
                defer { l.content = .shape(sh) }
                let r = try f(&sh, &l)
                refreshShape(snapshot, &sh)
                return r
            }) else { throw EngineError.noLayer(id) }
            return r
        }
    }

    static func defaultName(_ kind: String) -> String {
        switch kind {
        case "rect", "rectangle": "Rectangle"
        case "roundedRect", "roundRect": "Rounded Rectangle"
        case "ellipse": "Ellipse"
        case "polygon": "Polygon"
        case "star": "Star"
        case "line": "Line"
        default: "Shape"
        }
    }

    static func fgColor(_ s: Session) -> PCColor {
        let fg = s.tools.foreground
        return .rgb(fg.x, fg.y, fg.z, fg.w)
    }

    static func shapeCreate(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "shape.create"
        let kind = p["kind"]?.stringValue ?? "rect"
        let path: VectorPath
        let live: LiveShape?
        if kind == "path" {
            guard let v = p["path"] else { throw EngineError.bad(cmd, "kind \"path\" needs `path`") }
            path = try parsePath(cmd, v)
            live = nil
        } else {
            let l = try liveFromParams(cmd, kind, p, nil)
            path = l.path
            live = l
        }
        let fgc = fgColor(s)
        let fill: Fill?
        let stroke: ShapeStroke?
        do {
            fill = try p["fill"].map(parseFill) ?? .solid(fgc)
            stroke = try p["stroke"].map { v throws(GeometryError) in try parseStroke(v, base: nil, fg: fgc) } ?? nil
        } catch { throw bad(cmd, error) }
        if let e = validateShape(path, stroke) { throw EngineError.bad(cmd, e) }
        // Add to an existing shape layer with a path operation (Shape tool in combine/subtract… mode).
        if let target = p["addTo"]?.uint64Value {
            let op: PathOp
            if let o = p["op"]?.stringValue {
                guard let x = opFrom(o) else { throw EngineError.bad(cmd, "unknown `op`") }
                op = x
            } else {
                op = .combine
            }
            let id = LayerId(target)
            try withShape(s, id, "Add Shape") { sh, _ in
                for var sp in path.subpaths {
                    sp.op = op
                    sh.path.subpaths.append(sp)
                }
                sh.live = nil
                sh.psdRaw = nil
                if let e = validateShape(sh.path, sh.stroke) { throw EngineError.bad(cmd, e) }
            }
            return try shapeInfo(s, id)
        }
        let name = p["name"]?.stringValue
        let id = try s.edit("New Shape Layer") { doc, active -> LayerId in
            var sh = ShapeLayer(path: path, fill: fill, stroke: stroke, live: live)
            refreshShape(doc, &sh)
            let layer = Layer(name: name ?? doc.nextLayerName(defaultName(kind)), content: .shape(sh))
            let id = doc.insertAbove(active, layer)
            active = id
            return id
        }
        return try shapeInfo(s, id)
    }

    static func shapeEdit(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "shape.edit"
        let id = try s.layerParam(p)
        let fgc = fgColor(s)
        let name = p["name"]?.stringValue
        try withShape(s, id, "Edit Shape") { sh, layer in
            if let v = p["path"] {
                sh.path = try parsePath(cmd, v)
                sh.live = nil
                sh.psdRaw = nil
            }
            let geomKeys = ["kind", "rect", "radii", "radius", "sides", "starRatio", "from", "to", "weight"]
            if geomKeys.contains(where: { p[$0] != nil }) {
                guard var kind = p["kind"]?.stringValue ?? sh.live.map(liveKind) else {
                    throw EngineError.bad(cmd, "this shape has no live-shape parameters; pass `kind` or `path`")
                }
                // Explicit radii on a plain rectangle keep it a (now rounded) rectangle.
                if kind == "rect", let r = radii(p), (0..<4).contains(where: { r[$0] > 0 }) { kind = "roundedRect" }
                let l = try liveFromParams(cmd, kind, p, sh.live)
                // Re-entering unchanged values must not regenerate a transformed outline.
                if sh.live != l {
                    sh.path = l.path
                    sh.live = l
                    sh.psdRaw = nil
                }
            }
            if let mm = nums(p, "transform", 6) { transformShape(&sh, PCAffine(m: mm)) }
            if let d = nums(p, "move", 2) { transformShape(&sh, .translate(d[0], d[1])) }
            if let o = p["op"]?.stringValue {
                guard let op = opFrom(o) else { throw EngineError.bad(cmd, "unknown op `\(o)`") }
                if let iv = p["subpath"]?.uint64Value {
                    guard let i = Int(exactly: iv), i < sh.path.subpaths.count else { throw EngineError.bad(cmd, "no such subpath") }
                    sh.path.subpaths[i].op = op
                } else {
                    for i in sh.path.subpaths.indices.dropFirst() { sh.path.subpaths[i].op = op }
                }
                sh.live = nil
            }
            if let r = p["fillRule"]?.stringValue {
                sh.path.fillRule = r.lowercased() == "evenodd" ? .evenOdd : .nonZero
            }
            do {
                if let v = p["fill"] { sh.fill = try parseFill(v) }
                if let v = p["stroke"] { sh.stroke = try parseStroke(v, base: sh.stroke, fg: fgc) }
            } catch { throw bad(cmd, error) }
            if let n = name { layer.name = n }
            if let e = validateShape(sh.path, sh.stroke) { throw EngineError.bad(cmd, e) }
        }
        return try shapeInfo(s, id)
    }

    static func shapeRasterize(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let id = try s.layerParam(p)
        try s.edit("Rasterize Shape") { doc, _ in
            let snapshot = doc
            let fmt = snapshot.pixelFormat
            let done: Void? = try doc.updateLayer(id) { l in
                guard case .shape(var sh) = l.content else { throw EngineError.other("layer \(id.rawValue) is not a shape layer") }
                if sh.cache == nil { refreshShape(snapshot, &sh) }
                let surface = sh.cache ?? Surface(format: fmt)
                l.content = .raster(surface.format == fmt ? surface : surface.convertedAny(to: fmt))
                l.psdBlocks.removeAll { shapeBlocks.contains($0.key) }
            }
            if done == nil { throw EngineError.noLayer(id) }
        }
        return ["layer": .id(id)]
    }

    /// Layer › Rasterize › Shape without `layer`: every selected shape layer, sharing one history
    /// step (photocraft `extra_cmds::rasterize(s, p, Some("shape"))`).
    static func rasterizeSelectedShapes(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let ids = try LayerMulti.targets(s, p)
        let many = ids.count > 1
        let key = "rasterize#\(s.active?.revision ?? 0)"
        var done: [LayerId] = []
        for id in ids {
            guard let l = s.active?.doc.layer(id), case .shape = l.content else { continue }
            try s.execute("layer.rasterize.shape", ["layer": .id(id), "coalesce": .string(key)])
            done.append(id)
        }
        guard let first = done.first else {
            throw EngineError.other(many ? "none of the selected layers is a shape layer" : "the layer is not a shape layer")
        }
        let active = s.active?.activeLayer.flatMap { done.contains($0) ? $0 : nil }
        return ["layer": .id(active ?? first), "layers": .ids(done)]
    }

    // MARK: - Document paths

    /// `"work"`, `"Work Path"`, empty or absent name the work path.
    static func isWork(_ name: String?) -> Bool {
        guard let n = name else { return true }
        return n.isEmpty || n.lowercased() == "work" || n == "Work Path"
    }

    /// The path a command targets: the work path (falling back to the active layer's shape path or
    /// vector mask), `"layer"` → the active layer's, otherwise a saved path by name.
    static func resolvePath(_ s: Session, _ name: String?) throws -> VectorPath {
        guard let d = s.active else { throw EngineError.noDocument }
        func layerPath() -> VectorPath? {
            guard let id = d.activeLayer, let l = d.doc.layer(id) else { return nil }
            if case .shape(let sh) = l.content { return sh.path }
            return l.vectorMask?.path
        }
        if name == "layer" {
            guard let p = layerPath() else { throw EngineError.other("active layer has no shape path or vector mask") }
            return p
        }
        if isWork(name) {
            guard let p = d.doc.workPath ?? layerPath() else { throw EngineError.other("no work path") }
            return p
        }
        let n = name ?? ""
        guard let p = d.doc.paths.first(where: { $0.name == n }) else { throw EngineError.other("no path named \"\(n)\"") }
        return p.path
    }

    /// Edits the path a command targets, except a shape layer's (use `withShape`): `layer`'s vector
    /// mask when given, else the work path or a saved path (photocraft `path_mut`).
    static func withPath<R>(_ doc: inout Document, _ name: String, _ layer: LayerId?, _ body: (inout VectorPath) throws -> R) throws -> R {
        if let id = layer {
            guard doc.layer(id) != nil else { throw EngineError.noLayer(id) }
            let r: R?? = try doc.updateLayer(id) { l -> R? in
                guard var vm = l.vectorMask else { return nil }
                let r = try body(&vm.path)
                l.vectorMask = vm
                return r
            }
            guard let rr = r, let out = rr else { throw EngineError.other("active layer has no shape path or vector mask") }
            return out
        }
        if isWork(name) {
            guard var p = doc.workPath else { throw EngineError.other("no work path") }
            let r = try body(&p)
            doc.workPath = p
            return r
        }
        guard let i = doc.paths.firstIndex(where: { $0.name == name }) else { throw EngineError.other("no path named \"\(name)\"") }
        return try body(&doc.paths[i].path)
    }

    static func knotCount(_ p: VectorPath) -> Int { p.subpaths.reduce(0) { $0 + $1.knots.count } }

    static func pathsList(_ s: Session) throws -> JSONValue {
        guard let d = s.active else { throw EngineError.noDocument }
        let doc = d.doc
        var layer: JSONValue = .null
        if let id = d.activeLayer, let l = doc.layer(id) {
            if case .shape(let sh) = l.content {
                layer = ["kind": "shape", "layer": .id(l.id), "name": .string("\(l.name) Shape Path"), "knots": .int(knotCount(sh.path))]
            } else if let v = l.vectorMask {
                layer = ["kind": "vectorMask", "layer": .id(l.id), "name": .string("\(l.name) Vector Mask"), "knots": .int(knotCount(v.path))]
            }
        }
        return [
            "paths": .array(doc.paths.map { ["name": .string($0.name), "knots": .int(knotCount($0.path)), "subpaths": .int($0.path.subpaths.count)] }),
            "workPath": doc.workPath.map { ["knots": .int(knotCount($0)), "subpaths": .int($0.subpaths.count)] } ?? .null,
            "clippingPath": doc.clippingPath.map { ["name": .string($0.name), "flatness": .float($0.flatness)] } ?? .null,
            "layerPath": layer,
        ]
    }

    static func pathSet(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "path.set"
        guard let pv = p["path"] else { throw EngineError.bad(cmd, "missing `path`") }
        let path = try parsePath(cmd, pv)
        let name = p["name"]?.stringValue
        var append: PathOp?
        if let o = p["op"]?.stringValue {
            guard let op = opFrom(o) else { throw EngineError.bad(cmd, "unknown op `\(o)`") }
            append = op
        }
        try s.edit(isWork(name) ? "Work Path" : "Save Path") { doc, _ in
            func merge(_ old: VectorPath?, _ new: VectorPath) -> VectorPath {
                guard var o = old, let op = append else { return new }
                o.subpaths.append(contentsOf: new.subpaths.map { $0.withOp(op) })
                return o
            }
            if isWork(name) {
                doc.workPath = merge(doc.workPath, path)
            } else {
                let n = name ?? ""
                if let i = doc.paths.firstIndex(where: { $0.name == n }) {
                    doc.paths[i].path = merge(doc.paths[i].path, path)
                } else {
                    doc.paths.append(NamedPath(name: n, path: path, psdRaw: nil))
                }
            }
        }
        let out = try resolvePath(s, name)
        return ["name": .string(name ?? "work"), "path": pathJSON(out)]
    }

    static func pathDelete(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let name = p["name"]?.stringValue
        try s.edit("Delete Path") { doc, _ in
            if isWork(name) {
                guard doc.workPath != nil else { throw EngineError.other("no work path") }
                doc.workPath = nil
                return
            }
            let n = name ?? ""
            let before = doc.paths.count
            doc.paths.removeAll { $0.name == n }
            if doc.paths.count == before { throw EngineError.other("no path named \"\(n)\"") }
            if doc.clippingPath?.name == n { doc.clippingPath = nil }
        }
        return .null
    }

    static func clippingPathSet(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "path.clippingPath.set"
        guard let name = p["name"]?.stringValue, !name.isEmpty else { throw EngineError.bad(cmd, "missing saved path `name`") }
        var flatness: Float = 0
        if let value = p["flatness"] {
            guard let v = value.doubleValue, v.isFinite, v >= 0, v <= 100 else { throw EngineError.bad(cmd, "`flatness` must be between 0 and 100") }
            flatness = Float(v)
        }
        try s.edit("Clipping Path") { doc, _ in
            if !doc.paths.contains(where: { $0.name == name }) { throw EngineError.other("no saved path named \"\(name)\"") }
            doc.clippingPath = ClippingPath(name: name, flatness: flatness)
        }
        return ["name": .string(name), "flatness": .float(flatness)]
    }

    static func clippingPathClear(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        try s.edit("Clear Clipping Path") { doc, _ in
            guard doc.clippingPath != nil else { throw EngineError.other("no clipping path") }
            doc.clippingPath = nil
        }
        return .null
    }

    /// The path `path.transform` edits: `layer`'s shape path or vector mask, else the work path or
    /// a saved path.
    static func transformTarget(_ s: Session, _ name: String, _ layer: LayerId?) throws -> VectorPath {
        guard let id = layer else { return try resolvePath(s, name) }
        guard let d = s.active else { throw EngineError.noDocument }
        guard let l = d.doc.layer(id) else { throw EngineError.noLayer(id) }
        if case .shape(let sh) = l.content { return sh.path }
        guard let v = l.vectorMask else { throw EngineError.other("target layer has no shape path or vector mask") }
        return v.path
    }

    /// `n` numbers at `key` (`[x0, y0, x1, y1]` or `[[x, y] × 4]`, flattened), finite with
    /// magnitude ≤ 1000000; nil when absent.
    static func coords(_ p: JSONValue, _ key: String, _ n: Int) throws -> [Double]? {
        guard let v = p[key] else { return nil }
        let flat: [JSONValue]
        if let a = v.arrayValue {
            flat = a.allSatisfy({ $0.arrayValue != nil }) ? a.flatMap { $0.arrayValue ?? [] } : a
        } else {
            flat = []
        }
        let numbers = flat.compactMap(\.doubleValue).filter { $0.isFinite && abs($0) <= 1_000_000 }
        if flat.count != n || numbers.count != n {
            throw EngineError.bad("path.transform", "`\(key)` must hold \(n) finite numbers with magnitude at most 1000000")
        }
        return numbers
    }

    /// How `path.transform` moves the path.
    enum PathMap {
        case affine(PCAffine)
        case projective(Homography)
        case warp(Warp)
    }

    static func pathTransform(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "path.transform"
        let name = p["name"]?.stringValue ?? "work"
        let layerId: LayerId? = try name == "layer" ? s.layerParam(p) : nil
        // The box Distort, Perspective and Warp frame: `rect`, else the path's control bounds.
        func frame() throws -> [Double] {
            let r: [Double]
            if let c = try coords(p, "rect", 4) {
                r = c
            } else {
                guard let b = try transformTarget(s, name, layerId).controlBounds else { throw EngineError.bad(cmd, "path has no points to transform") }
                r = [b.x, b.y, b.z, b.w]
            }
            if r[2] - r[0] <= 0 || r[3] - r[1] <= 0 {
                throw EngineError.bad(cmd, "`rect` must have a positive width and height (a straight path needs a `rect`)")
            }
            return r
        }
        let map: PathMap
        if let values = p["matrix"] {
            guard let a = values.arrayValue, a.count == 6 else { throw EngineError.bad(cmd, "`matrix` must contain six numbers") }
            var mm: [Double] = []
            for v in a {
                guard let x = v.doubleValue, x.isFinite, abs(x) <= 1_000_000 else {
                    throw EngineError.bad(cmd, "matrix entries must be finite numbers with magnitude at most 1000000")
                }
                mm.append(x)
            }
            map = .affine(PCAffine(m: mm))
        } else if let q = try coords(p, "quad", 8) {
            // Distort and Perspective: where the frame's corners go, clockwise from top-left.
            let quad = [SIMD2(q[0], q[1]), SIMD2(q[2], q[3]), SIMD2(q[4], q[5]), SIMD2(q[6], q[7])]
            guard let h = try Homography.rectToQuad(frame(), quad), h.m.allSatisfy(\.isFinite), h.inverse != nil else {
                throw EngineError.bad(cmd, "degenerate quad")
            }
            let (a, b, c, d, e, f, g, hh, i) = (h.m[0], h.m[1], h.m[2], h.m[3], h.m[4], h.m[5], h.m[6], h.m[7], h.m[8])
            if abs(g) < 1e-12 && abs(hh) < 1e-12 && abs(i) > 1e-12 {
                // A parallelogram is affine: a live shape stays live.
                map = .affine(PCAffine(m: [a / i, d / i, b / i, e / i, c / i, f / i]))
            } else {
                map = .projective(h)
            }
        } else if ["warp", "style", "mesh"].contains(where: { p[$0] != nil }) {
            let fr = try frame()
            let w = try warpFromParams(cmd, p, SIMD4(fr[0], fr[1], fr[2], fr[3]))
            let values = [w.bend, w.hDistort, w.vDistort, w.bounds.x, w.bounds.y, w.bounds.z, w.bounds.w]
            if values.contains(where: { !$0.isFinite || abs($0) > 1_000_000 }) {
                throw EngineError.bad(cmd, "warp values must be finite numbers with magnitude at most 1000000")
            }
            map = .warp(w)
        } else {
            func number(_ key: String, _ d: Double) throws -> Double {
                guard let v = p[key] else { return d }
                guard let x = v.doubleValue, x.isFinite, abs(x) <= 1_000_000 else {
                    throw EngineError.bad(cmd, "`\(key)` must be a finite number with magnitude at most 1000000")
                }
                return x
            }
            if !["translateX", "translateY", "scaleX", "scaleY", "angle"].contains(where: { p[$0] != nil }) {
                throw EngineError.bad(cmd, "pass `matrix`, `quad`, a warp (`style`, `mesh` or `warp`) or translate/scale/angle parameters")
            }
            let tx = try number("translateX", 0), ty = try number("translateY", 0)
            let sx = try number("scaleX", 1), sy = try number("scaleY", 1)
            let angle = try number("angle", 0)
            // An explicit `layer` determines both the transformed path and its pivot (#3062).
            guard let b = try transformTarget(s, name, layerId).controlBounds else { throw EngineError.bad(cmd, "path has no points to transform") }
            let cx = (b.x + b.z) * 0.5, cy = (b.y + b.w) * 0.5
            map = .affine(PCAffine.translate(-cx, -cy).then(.scale(sx, sy)).then(.rotate(angle * .pi / 180)).then(.translate(cx + tx, cy + ty)))
        }
        let out: JSONValue
        switch map {
        case .affine(let a): out = ["name": .string(name), "matrix": .doubles(a.m)]
        case .projective(let h): out = ["name": .string(name), "homography": .doubles(h.m)]
        case .warp: out = ["name": .string(name), "warp": true]
        }
        if let id = layerId, let l = s.active?.doc.layer(id), case .shape = l.content {
            try withShape(s, id, "Transform Path") { sh, _ in
                switch map {
                case .affine(let a): transformShape(&sh, a)
                case .projective(let h): try mapShape(&sh, homography: h, warp: nil)
                case .warp(let w): try mapShape(&sh, homography: nil, warp: w)
                }
                sh.psdRaw = nil
            }
            return out
        }
        try s.edit("Transform Path") { doc, _ in
            try withPath(&doc, name, layerId) { path in
                switch map {
                case .affine(let a): path = path.transform(a)
                case .projective(let h): path = try mapPath(path, homography: h, warp: nil)
                case .warp(let w): path = try mapPath(path, homography: nil, warp: w)
                }
            }
        }
        return out
    }

    static func pathRename(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "path.rename"
        let name = p["name"]?.stringValue
        guard let to = p["to"]?.stringValue, !to.isEmpty else { throw EngineError.bad(cmd, "missing `to`") }
        if isWork(to) { throw EngineError.bad(cmd, "`to` cannot name the work path") }
        try s.edit(isWork(name) ? "Save Path" : "Rename Path") { doc, _ in
            if doc.paths.contains(where: { $0.name == to }) { throw EngineError.other("a path named \"\(to)\" already exists") }
            if isWork(name) {
                // Photoshop: saving the work path turns it into a named path.
                guard let path = doc.workPath else { throw EngineError.other("no work path") }
                doc.workPath = nil
                doc.paths.append(NamedPath(name: to, path: path, psdRaw: nil))
                return
            }
            let n = name ?? ""
            guard let i = doc.paths.firstIndex(where: { $0.name == n }) else { throw EngineError.other("no path named \"\(n)\"") }
            doc.paths[i].name = to
            if doc.clippingPath?.name == n { doc.clippingPath?.name = to }
        }
        return ["name": .string(to)]
    }

    static func pathToSelection(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let path = try resolvePath(s, p["name"]?.stringValue)
        let feather = Float(f64(p, "feather") ?? 0)
        let aa = p["antiAlias"]?.boolValue ?? true
        let mode = SelectionMath.Mode.parse(p["mode"]?.stringValue ?? "replace")
        guard let area = s.active?.doc.bounds else { throw EngineError.noDocument }
        var mask = VectorRasterizer.fillCoverage(rasterSafe(path, within: area), rect: area)
        if !aa { for i in mask.indices { mask[i] = mask[i] >= 0.5 ? 1 : 0 } }
        if feather > 0 { mask = VectorCommands.feather(mask, area.width, area.height, feather) }
        let selected = try s.edit("Make Selection") { doc, _ -> Bool in
            doc.selection = SelectionMath.combine(doc.selection, mask, area, mode)
            return doc.selection != nil
        }
        return ["selected": .bool(selected)]
    }

    static func selectToWorkPath(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let tol = min(max(f64(p, "tolerance") ?? 2, 0.5), 10)
        guard let d = s.active else { throw EngineError.noDocument }
        let area = d.doc.bounds
        guard let sel = d.doc.selection else { throw EngineError.other("no selection") }
        let mask = SelectionMath.mask(from: sel, area)
        let path = traceMask(mask, area, outside: 0, tolerance: tol)
        let knots = knotCount(path), subpaths = path.subpaths.count
        try s.edit("Make Work Path") { doc, _ in doc.workPath = path }
        return ["subpaths": .int(subpaths), "knots": .int(knots)]
    }

    /// Pixel bounds a path's fill can touch; nil when unbounded (inverted) or empty.
    static func pixelBounds(_ path: VectorPath) -> PixelRect? {
        if path.inverted { return nil }
        let b = VectorGeometry.fillArea(path).boundingBoxOfPath
        guard !b.isNull, !b.isEmpty, b.minX.isFinite, b.maxX.isFinite else { return nil }
        func c(_ v: CGFloat) -> Int32 { Int32(min(max(Double(v), -2e9), 2e9)) }
        return PixelRect(x0: c(b.minX.rounded(.down)), y0: c(b.minY.rounded(.down)), x1: c(b.maxX.rounded(.up)), y1: c(b.maxY.rounded(.up)))
    }

    static func lockedMessage(_ name: String) -> String { "Could not complete your request because the layer \"\(name)\" is locked" }

    static func pathFill(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let path = try resolvePath(s, p["name"]?.stringValue)
        let c = color(p["color"]) ?? fgColor(s)
        let rgb = c.rgb
        let src = SIMD4<Float>(rgb.x, rgb.y, rgb.z, c.alpha)
        let opacity = Float(min(max((f64(p, "opacity") ?? 100) / 100, 0), 1))
        let mode = p["mode"]?.stringValue.flatMap(Params.blendMode) ?? .normal
        let feather = Float(f64(p, "feather") ?? 0)
        let aa = p["antiAlias"]?.boolValue ?? true
        let id = try s.layerParam(p)
        try s.edit("Fill Path") { doc, _ in
            var area = doc.bounds
            let path = rasterSafe(path, within: area)
            // The feather reaches 3σ = 3 × radius (σ = radius, as in Photoshop), plus a pixel.
            let fc = Double(feather).rounded(.up)
            let ci = fc.isNaN ? 0 : Int64(min(max(fc, -3e9), 3e9))
            let pad = Int32(clamping: Int64(Int32(clamping: ci)) * 3 + 1)
            if let b = pixelBounds(path) { area = b.outset(by: pad).intersect(area) }
            if area.isEmpty { return }
            var cov = VectorRasterizer.fillCoverage(path, rect: area)
            if !aa { for i in cov.indices { cov[i] = cov[i] >= 0.5 ? 1 : 0 } }
            if feather > 0 { cov = VectorCommands.feather(cov, area.width, area.height, feather) }
            // An active selection limits the fill, soft edges included (#2387).
            if let selection = doc.selection {
                let mask = SelectionMath.mask(from: selection, area)
                for i in cov.indices { cov[i] *= mask[i] }
            }
            let locks = doc.effectiveLocks(id)
            guard let l = doc.layer(id) else { throw EngineError.noLayer(id) }
            if locks.pixels || locks.all { throw EngineError.other(lockedMessage(l.name)) }
            guard case .raster = l.content else { throw EngineError.other("Fill Path needs a pixel layer") }
            doc.updateLayer(id) { l in
                l.withRaster { surf in paintCoverage(&surf, area, cov, src, opacity, mode, locks.transparency) }
            }
        }
        return .null
    }

    /// Composites `src` × coverage onto a surface over `area` (any pixel format).
    static func paintCoverage(_ surf: inout Surface, _ area: PixelRect, _ cov: [Float], _ src: SIMD4<Float>, _ opacity: Float, _ mode: BlendMode, _ lockAlpha: Bool) {
        let fmt = surf.format
        let ch = fmt.channels
        var vals = surf.readRegion(area)
        guard vals.count == cov.count * ch else { return }
        for (i, c) in cov.enumerated() where c > 0 {
            let dst = vals.withUnsafeBufferPointer { PixelCodec.toRGBA(fmt, $0, i * ch) }
            var out = PSBlend.composite(mode, dst, SIMD4(src.x, src.y, src.z, src.w * c), opacity, .srgb)
            if lockAlpha { out.w = dst.w }
            let enc = PixelCodec.fromRGBA(fmt, out)
            for k in 0..<min(ch, enc.count) { vals[i * ch + k] = enc[k] }
        }
        surf.writeRegion(area, vals)
        surf.prune()
    }

    /// Stroke Path's brush-based tools besides the Brush, Pencil and Eraser it renders itself: each
    /// paints the path with its own `paint.*` command.
    static let strokePathTools: [(String, String)] = [
        ("backgroundEraser", "paint.backgroundEraser"), ("cloneStamp", "paint.cloneStamp"), ("patternStamp", "paint.patternStamp"),
        ("healingBrush", "paint.healingBrush"), ("spotHealingBrush", "paint.spotHealing"), ("historyBrush", "paint.historyBrush"),
        ("blur", "paint.blur"), ("sharpen", "paint.sharpen"), ("smudge", "paint.smudge"), ("dodge", "paint.dodge"), ("burn", "paint.burn"),
        ("sponge", "paint.sponge"), ("colorReplacement", "paint.colorReplacement"), ("mixerBrush", "paint.mixerBrush"),
    ]

    /// At most this many points per subpath when Simulate Pressure resamples it.
    static let maxPressurePoints = 200_000.0

    /// The stroke points along one flattened subpath; with `simulate` the pressure rises from 0 to
    /// full at the middle and falls back to 0 (Stroke Path's Simulate Pressure).
    static func strokePoints(_ pts: [SIMD2<Double>], closed: Bool, simulate: Bool) -> [StrokePoint] {
        var line = pts
        if closed, let first = pts.first { line.append(first) }
        func full(_ l: [SIMD2<Double>]) -> [StrokePoint] { l.map { StrokePoint($0.x, $0.y, 1) } }
        if !simulate || line.count < 2 { return full(line) }
        var total = 0.0
        for i in 1..<line.count { total += simd_distance(line[i - 1], line[i]) }
        if !(total.isFinite && total > 0) { return full(line) }
        let step = max(total / maxPressurePoints, 1)
        func pressure(_ d: Double) -> Float { Float(min(max(sin(d / total * .pi), 0), 1)) }
        var out: [StrokePoint] = []
        var walked = 0.0
        for i in 1..<line.count {
            let a = line[i - 1], b = line[i]
            let len = simd_distance(a, b)
            let n = Int(min(max((len / step).rounded(.up), 1), maxPressurePoints))
            for j in 0..<n {
                let t = Double(j) / Double(n)
                out.append(StrokePoint(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, pressure(walked + len * t)))
            }
            walked += len
        }
        if let last = line.last { out.append(StrokePoint(last.x, last.y, 0)) }
        return out
    }

    /// photocraft `analysis_cmds::compound`: runs `f` (which may run other commands) as one history
    /// step labelled `label`; on failure the document and its view state are restored.
    static func compound<R>(_ s: Session, _ label: String, _ f: () throws -> R) throws -> R {
        guard let st = s.active else { throw EngineError.noDocument }
        let (before, history, prior, view) = (st.doc, st.history, st.layerTarget, st.view)
        let journal = s.journal.count
        let r: Result<R, any Error>
        do { r = .success(try f()) } catch { r = .failure(error) }
        if case .failure = r, s.journal.count > journal { s.journal.removeSubrange(journal...) }
        try s.updateActive { st in
            st.history = history
            switch r {
            case .success:
                st.history.setCurrentLayers(prior)
                st.history.record(label, before: before, layers: st.layerTarget)
                _ = st.history.trim(st.doc)
                st.coalesce = nil
            case .failure:
                st.doc = before
                st.view = view
                st.fixSelection()
                st.revision += 1
                st.lastDamage = nil
            }
        }
        if case .failure = r, let st = s.active {
            s.emit(.documentChanged(st.id, revision: st.revision, damage: nil))
            s.publish()
        }
        return try r.get()
    }

    /// Stroke Path with a tool that has its own `paint.*` command: run once per subpath with the
    /// caller's params and the path's points, all in one history step; only `path.stroke` stays in
    /// the journal.
    static func strokeWithCommand(_ s: Session, _ p: JSONValue, _ cmd: String, _ lines: [Polyline], _ simulate: Bool) throws -> JSONValue {
        var params = p.members
        for k in ["name", "tool", "simulatePressure", "coalesce"] { params[k] = nil }
        let journal = s.journal.count
        let r: Result<PixelRect?, any Error>
        do {
            r = .success(try compound(s, "Stroke Path") { () throws -> PixelRect? in
                // The union of what each subpath's command changed; nil when one of them didn't say.
                var dmg: PixelRect? = .empty
                for pl in lines {
                    let pts = strokePoints(pl.pts, closed: pl.closed, simulate: simulate)
                    if pts.isEmpty { continue }
                    var call = params
                    call["points"] = .array(pts.map { [.number($0.x), .number($0.y), .float($0.pressure)] })
                    try s.execute(cmd, .object(call))
                    let d = s.active?.lastDamage
                    if let a = dmg, let b = d { dmg = a.isEmpty ? b : (b.isEmpty ? a : a.union(b)) } else { dmg = nil }
                }
                return dmg
            })
        } catch { r = .failure(error) }
        if s.journal.count > journal { s.journal.removeSubrange(journal...) }
        let dmg = try r.get()
        try? s.updateActive { $0.lastDamage = dmg }
        let out = dmg ?? s.active?.doc.bounds ?? .empty
        return ["damage": .rect(out)]
    }

    /// photocraft `brush_cmds::validate_brush`.
    static func validateBrush(_ b: BrushSettings, _ cmd: String) throws {
        let mx = maxBrushSize
        if !b.size.isFinite || b.size > mx { throw EngineError.bad(cmd, "brush size must be finite and at most \(Int(mx)) px") }
        if b.dualBrush.enabled && (!b.dualBrush.size.isFinite || b.dualBrush.size > mx) {
            throw EngineError.bad(cmd, "dual brush size must be finite and at most \(Int(mx)) px")
        }
        let sm = maxScatter
        let sc = b.scattering.scatter.jitter
        if b.scattering.enabled && !(sc >= 0 && sc <= sm) {
            throw EngineError.bad(cmd, "scatter amount \(sc) is out of range: it must be between 0 and \(Int(sm)) (1000 %)")
        }
        let ds = b.dualBrush.scatter
        if b.dualBrush.enabled && !(ds >= 0 && ds <= sm) {
            throw EngineError.bad(cmd, "dual brush scatter amount \(ds) is out of range: it must be between 0 and \(Int(sm)) (1000 %)")
        }
    }

    static func pathStroke(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "path.stroke"
        let path = try resolvePath(s, p["name"]?.stringValue)
        let tool = p["tool"]?.stringValue ?? "brush"
        var simulate = false
        if let v = p["simulatePressure"], v != .null {
            guard let b = v.boolValue else { throw EngineError.bad(cmd, "`simulatePressure` must be true or false") }
            simulate = b
        }
        if let t = strokePathTools.first(where: { $0.0 == tool }) {
            return try strokeWithCommand(s, p, t.1, flattenPath(path, 0.1), simulate)
        }
        let fg = s.tools.foreground
        var brush = s.tools.brush
        if let v = f64(p, "size") { brush.size = Float(v) }
        if let v = f64(p, "hardness") { brush.hardness = Float(v) }
        if let v = f64(p, "opacity") { brush.opacity = Float(v / 100) }
        brush.color = color(p["color"]).map { SIMD4($0.rgb, $0.alpha) } ?? fg
        brush.erase = tool == "eraser"
        // The path is the exact geometry: stroke smoothing would cut its corners.
        brush.smoothing.amount = 0
        switch tool {
        case "pencil": brush.hardness = 1
        case "brush", "eraser": break
        default:
            let tools = ["brush", "pencil", "eraser"] + strokePathTools.map(\.0)
            throw EngineError.bad(cmd, "unknown tool `\(tool)` (\(tools.joined(separator: "|")))")
        }
        try validateBrush(brush, cmd)
        let lines = flattenPath(path, 0.1)
        let id = try s.layerParam(p)
        let bg = s.tools.background
        let dmg = try s.edit("Stroke Path") { doc, _ -> PixelRect in
            let sel = doc.selection
            let locks = doc.effectiveLocks(id)
            guard let l = doc.layer(id) else { throw EngineError.noLayer(id) }
            // Pixel and full locks refuse the stroke, as Fill Path does (#2388).
            if locks.pixels || locks.all { throw EngineError.other(lockedMessage(l.name)) }
            let lock = locks.transparency
            guard case .raster = l.content else { throw EngineError.other("Stroke Path needs a pixel layer") }
            var b = brush
            if b.erase && lock {
                // Locked transparency (e.g. the Background): the Eraser paints the background colour (#76).
                b.erase = false
                b.color = bg
            }
            var dmg = PixelRect.empty
            doc.updateLayer(id) { l in
                l.withRaster { surf in
                    for pl in lines {
                        let pts = strokePoints(pl.pts, closed: pl.closed, simulate: simulate)
                        if pts.isEmpty { continue }
                        let r = applyStroke(&surf, Stroke(brush: b, points: pts), selection: sel, lockTransparency: lock)
                        dmg = dmg.isEmpty ? r : dmg.union(r)
                    }
                }
            }
            return dmg
        }
        return ["damage": .rect(dmg)]
    }

    // MARK: - Vector masks

    static func vectorMaskInfo(_ s: Session, _ id: LayerId) throws -> JSONValue {
        guard let d = s.active else { throw EngineError.noDocument }
        guard let l = d.doc.layer(id) else { throw EngineError.noLayer(id) }
        guard let v = l.vectorMask else { return ["layer": .id(id), "vectorMask": .null] }
        return ["layer": .id(id), "path": pathJSON(v.path), "enabled": .bool(v.enabled), "linked": .bool(v.linked),
                "density": .float(v.density * 100), "feather": .float(v.feather)]
    }

    static func vectorMaskAdd(_ s: Session, _ p: JSONValue, fromPath: Bool) throws -> JSONValue {
        let cmd = "layer.vectorMask.add"
        let id = try s.layerParam(p)
        var path: VectorPath
        if let v = p["path"] {
            path = try parsePath(cmd, v)
        } else if fromPath || p["name"] != nil {
            let name = p["name"]?.stringValue
            // Never fall back to the layer's own path here.
            if isWork(name) {
                guard let w = s.active?.doc.workPath else { throw EngineError.other("no work path") }
                path = w
            } else {
                path = try resolvePath(s, name)
            }
        } else {
            path = VectorPath()
        }
        if p["hide"]?.boolValue ?? false { path.inverted.toggle() }
        try s.edit("Add Vector Mask") { doc, _ in
            let locked = doc.effectiveLocks(id).all
            guard let l = doc.layer(id) else { throw EngineError.noLayer(id) }
            if case .shape = l.content { throw EngineError.other("a shape layer's path is already its vector mask") }
            if locked { throw EngineError.other("layer \"\(l.name)\" is locked") }
            doc.updateLayer(id) { $0.vectorMask = VectorMask(path: path) }
        }
        return try vectorMaskInfo(s, id)
    }

    static func vectorMaskEdit(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "layer.vectorMask.edit"
        let id = try s.layerParam(p)
        let path = try p["path"].map { try parsePath(cmd, $0) }
        try s.edit("Edit Vector Mask") { doc, _ in
            guard let l = doc.layer(id) else { throw EngineError.noLayer(id) }
            guard var vm = l.vectorMask else { throw EngineError.other("layer has no vector mask") }
            if let pth = path { vm.path = pth }
            if let b = p["enabled"]?.boolValue { vm.enabled = b }
            if let b = p["linked"]?.boolValue { vm.linked = b }
            if let d = f64(p, "density") { vm.density = Float(min(max(d / 100, 0), 1)) }
            if let f = f64(p, "feather") { vm.feather = Float(max(f, 0)) }
            if p["invert"]?.boolValue == true { vm.path.inverted.toggle() }
            doc.updateLayer(id) { $0.vectorMask = vm }
        }
        return try vectorMaskInfo(s, id)
    }

    static func vectorMaskDelete(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let id = try s.layerParam(p)
        try s.edit("Delete Vector Mask") { doc, _ in
            guard let l = doc.layer(id) else { throw EngineError.noLayer(id) }
            guard l.vectorMask != nil else { throw EngineError.other("layer has no vector mask") }
            doc.updateLayer(id) { $0.vectorMask = nil }
        }
        return .null
    }

    /// The mask the compositor shows for `l` over `area` (photocraft `masks::combined_mask`): the
    /// layer's masks over an opaque white layer, composited alone; its alpha is the mask.
    static func shownMask(_ renderer: EngineRenderer, _ doc: Document, _ l: Layer, _ area: PixelRect) throws -> [Float] {
        let fmt = PixelFormat(mode: .rgb, sample: .f32, alpha: true)
        var probe = Layer.raster("mask", format: fmt)
        probe.withRaster { $0.fill(area, with: [1, 1, 1, 1]) }
        probe.mask = l.mask
        probe.vectorMask = l.vectorMask
        var solo = Document(name: "mask", size: doc.size, mode: .rgb, depth: .f32)
        solo.layers = [probe]
        let out = try renderer.compositeToSurface(solo, rect: area, format: fmt)
        return out.readRGBA(area).map(\.w)
    }

    /// Layer › Rasterize › Vector Mask: multiplies the vector mask into the pixel mask; when a
    /// feather or the pixel mask's density shapes the rendered edge, the pixel mask becomes exactly
    /// what the compositor showed (#992).
    static func vectorMaskRasterize(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let id = try s.layerParam(p)
        let renderer = s.services.renderer
        try s.edit("Rasterize Vector Mask") { doc, _ in
            let area = doc.bounds
            let depth = doc.depth
            guard let l = doc.layer(id) else { throw EngineError.noLayer(id) }
            let vEnabled = l.vectorMask?.enabled ?? false
            let soft = vEnabled && ((l.vectorMask.map { MaskSpec.featherSigma($0.feather) > 0 } ?? false)
                || (l.mask.map { $0.enabled && (MaskSpec.featherSigma($0.feather) > 0 || $0.density < 1) } ?? false))
            let shown = try soft ? shownMask(renderer, doc, l, area) : nil
            guard let vm = l.vectorMask else { throw EngineError.other("layer has no vector mask") }
            var mask = l.mask ?? LayerMask(surface: Surface(format: PixelFormat(mode: .grayscale, sample: depth, alpha: false), defaultPixel: [1]))
            if let shown {
                // Past the canvas the pixel mask keeps its own (density-applied) default.
                let d = mask.surface.defaultPixelValue.first ?? 1
                var surface = Surface(format: mask.surface.format, defaultPixel: [1 - mask.density * (1 - d)])
                surface.writeRegion(area, shown)
                surface.prune()
                mask.surface = surface
                mask.feather = 0
                mask.density = 1
            } else {
                var safe = vm
                safe.path = rasterSafe(vm.path, within: area)
                let vals = VectorRasterizer.coverage(of: safe, rect: area)
                // Outside the canvas the vector mask is 0 unless it is empty/inverted; keep the old default there.
                let old = mask.surface.readRegion(area)
                mask.surface.writeRegion(area, zip(old, vals).map { $0 * $1 })
                mask.surface.prune()
            }
            doc.updateLayer(id) { l in
                l.vectorMask = nil
                l.mask = mask
            }
        }
        return ["layer": .id(id)]
    }

    static func toggleVectorMask(_ s: Session, _ p: JSONValue, _ key: String) throws -> JSONValue {
        let id = try s.layerParam(p)
        guard let d = s.active else { throw EngineError.noDocument }
        guard let l = d.doc.layer(id) else { throw EngineError.noLayer(id) }
        guard let vm = l.vectorMask else { throw EngineError.other("layer has no vector mask") }
        let cur = key == "enabled" ? vm.enabled : vm.linked
        let v = p[key]?.boolValue ?? !cur
        return try vectorMaskEdit(s, ["layer": .id(id), key: .bool(v)])
    }

    // MARK: - Combine Shapes

    /// Traces the exact coverage of the shape's path back into plain outlines.
    static func mergeComponents(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let tol = min(max(f64(p, "tolerance") ?? 0.1, 0.05), 10)
        if let ids = try combineTargets(s, p, ["layer"]) {
            return try mergeShapeLayers(s, ids, op: nil, label: "Merge Shape Components", bake: tol)
        }
        let id = try s.layerParam(p)
        try withShape(s, id, "Merge Shape Components") { sh, _ in try bakeComponents(&sh, tol) }
        return try shapeInfo(s, id)
    }

    /// Bakes `sh`'s path operations into plain combined outlines, traced from the exact coverage at
    /// 4× resolution.
    static func bakeComponents(_ sh: inout ShapeLayer, _ tol: Double) throws {
        let k = 4.0
        let up = sh.path.transform(.scale(k))
        guard let b0 = pixelBounds(up) else {
            sh.path.subpaths.removeAll()
            return
        }
        let b = b0.outset(by: 2)
        if b.width * b.height > 400_000_000 { throw EngineError.other("shape too large to merge") }
        let cov = VectorRasterizer.fillCoverage(up, rect: b)
        let traced = traceMask(cov, b, outside: 0, tolerance: tol * k)
        sh.path = traced.transform(.scale(1 / k))
        sh.live = nil
        sh.psdRaw = nil
    }

    /// The shape layers Combine Shapes merges: with none of `narrow` given and two or more shape
    /// layers selected, those bottom-to-top; nil keeps the single-layer behaviour.
    static func combineTargets(_ s: Session, _ p: JSONValue, _ narrow: [String]) throws -> [LayerId]? {
        if narrow.contains(where: { p[$0] != nil }) { return nil }
        guard let d = s.active else { throw EngineError.noDocument }
        let ids = LayerOps.topLevel(d.doc, d.selectedLayers).filter { id in
            if let l = d.doc.layer(id), case .shape = l.content { return true }
            return false
        }
        return ids.count > 1 ? ids : nil
    }

    /// Combine Shapes with several shape layers selected: merged into the top-most one; the bottom
    /// layer's components keep their operations, those above take `op` (or, without, keep theirs
    /// with each layer's first combined and the result baked with tolerance `bake`).
    static func mergeShapeLayers(_ s: Session, _ ids: [LayerId], op: PathOp?, label: String, bake: Double?) throws -> JSONValue {
        guard let keep = ids.last else { throw EngineError.other("Combine Shapes needs two or more shape layers") }
        if let st = s.active {
            for id in ids {
                let locks = st.doc.effectiveLocks(id)
                if locks.all || locks.pixels { throw EngineError.other("a selected shape layer is locked") }
            }
        }
        try s.edit(label) { doc, active in
            var path: VectorPath?
            for id in ids {
                guard let l = doc.layer(id) else { throw EngineError.noLayer(id) }
                guard case .shape(let sh) = l.content else { throw EngineError.other("layer \(id.rawValue) is not a shape layer") }
                guard var acc = path else {
                    path = sh.path
                    continue
                }
                for (j, sp0) in sh.path.subpaths.enumerated() {
                    var sp = sp0
                    if let op { sp.op = op } else if j == 0 { sp.op = .combine }
                    acc.subpaths.append(sp)
                }
                path = acc
            }
            guard let merged0 = path else { throw EngineError.other("Combine Shapes needs two or more shape layers") }
            let snapshot = doc
            guard let l = doc.layer(keep) else { throw EngineError.noLayer(keep) }
            guard case .shape(let sh) = l.content else { throw EngineError.other("layer \(keep.rawValue) is not a shape layer") }
            var merged = sh
            merged.path = merged0
            merged.live = nil
            merged.psdRaw = nil
            merged.cache = nil
            if let tol = bake { try bakeComponents(&merged, tol) }
            if let e = validateShape(merged.path, merged.stroke) { throw EngineError.bad(label, e) }
            refreshShape(snapshot, &merged)
            doc.updateLayer(keep) { $0.content = .shape(merged) }
            for id in ids where id != keep { doc.remove(id) }
            active = keep
        }
        LayerMulti.reselect(s, [keep], active: keep)
        return try shapeInfo(s, keep)
    }

    /// Layer › Combine Shapes › Unite / Subtract Front Shape / Intersect / Exclude.
    static func combineShapes(_ s: Session, _ p: JSONValue, _ op: String, _ label: String) throws -> JSONValue {
        if let ids = try combineTargets(s, p, ["layer", "subpath"]) {
            guard let o = opFrom(op) else { throw EngineError.other("unknown op `\(op)`") }
            return try mergeShapeLayers(s, ids, op: o, label: label, bake: nil)
        }
        return try shapeEdit(s, p.setting("op", .string(op)))
    }

    static func selectionToShape(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let tol = min(max(f64(p, "tolerance") ?? 2, 0.5), 10)
        guard let d = s.active else { throw EngineError.noDocument }
        let area = d.doc.bounds
        let mask = SelectionMath.mask(from: d.doc.selection, area)
        let path = traceMask(mask, area, outside: 0, tolerance: tol)
        var q: JSONValue = ["kind": "path", "path": pathJSON(path)]
        for k in ["fill", "name", "stroke"] { if let v = p[k] { q = q.setting(k, v) } }
        return try shapeCreate(s, q)
    }

    // MARK: - Specs

    static let combineParams = ##"{"layer":id?,"subpath":index? (default all but the first)} (no layer/subpath and two or more shape layers selected: merges them into the top-most, whose components above the bottom layer's take the operation)"##

    static let pathForm = ##"path: {"subpaths":[{"closed":bool=true,"op":"combine|subtract|intersect|exclude","knots":[[x,y] | {"anchor":[x,y],"in":[x,y],"out":[x,y],"smooth":bool}]}],"fillRule":"nonzero|evenodd","inverted":bool}"##

    static func register(into r: inout CommandRegistry) {
        let stroke = ##""stroke":{"width":px,"color":"#rrggbb"|fill,"opacity":0..100,"align":"inside|center|outside","cap":"butt|round|square","join":"miter|round|bevel","miterLimit":n,"dashes":[multiples of width],"dashOffset":n}|null"##
        let fill = ##""fill":"#rrggbb"|[r,g,b,a]|{"gradient":{"stops":[[t,"#hex"]],"angle":deg,"scale":%,"style":"linear|radial|angle|reflected|diamond","reverse":bool}}|{"pattern":name}|null (no fill)"##
        let shapeCreateParams = ##"{"kind":"rect|roundedRect|ellipse|polygon|star|line|path"="rect","rect":[x,y,w,h] (rect/roundedRect/ellipse/polygon/star),"radii":[tl,tr,br,bl]|r (roundedRect=10),"sides":3..100=5,"starRatio":0..1 (star=0.5),"from":[x,y],"to":[x,y],"weight":px=1 (line),"path":{…} (kind path),"## + fill + "=foreground," + stroke + ##"=none,"name":str?,"addTo":layerId? + "op":"combine|subtract|intersect|exclude" (append to an existing shape layer)} → shape.info. "## + pathForm
        let shapeEditParams = ##"{"layer":id?,"path":{…}? (replaces; drops live shape),"kind":str?,"rect":[x,y,w,h]?,"radii":[tl,tr,br,bl]|r?,"sides":n?,"starRatio":r?,"from":[x,y]?,"to":[x,y]?,"weight":px? (live-shape params regenerate the path),"move":[dx,dy]?,"transform":[a,b,c,d,e,f]?,"op":"combine|…"? + "subpath":index? (default all but the first),"fillRule":"nonzero|evenodd"?,"## + fill + "?," + stroke + ##"? (merged into the current stroke),"name":str?} → shape.info"##
        let pathSetParams = ##"{"name":str|"work"="work","path":{…},"op":"combine|subtract|intersect|exclude"? (append to the existing path with this op instead of replacing)}. "## + pathForm
        let vmEditParams = ##"{"layer":id?,"path":{…}?,"enabled":bool?,"linked":bool?,"density":0..100?,"feather":px?,"invert":true?}. "## + pathForm

        r.add([
            CommandSpec("shape.create", "New Shape Layer", menu: ["Layer", "New"], params: shapeCreateParams, module: m, enabled: hasDoc, run: shapeCreate),
            CommandSpec("shape.edit", "Edit Shape", params: shapeEditParams, module: m, enabled: hasLayer, run: shapeEdit),
            CommandSpec("shape.info", "Shape Layer Info", params: ##"{"layer":id?} → {layer,name,kind,path,fill,stroke,live,bounds:[x,y,w,h]}"##,
                        module: m, journal: false, enabled: hasLayer) { s, p in try shapeInfo(s, try s.layerParam(p)) },
            CommandSpec("shape.rasterize", "Rasterize Shape", menu: ["Layer", "Rasterize"], params: ##"{"layer":id?}"##, module: m, enabled: hasLayer, run: shapeRasterize),
            CommandSpec("path.list", "List Paths", params: ##"{} → {paths:[{name,knots,subpaths}],workPath,clippingPath,layerPath (active layer's shape path / vector mask)}"##,
                        module: m, journal: false, enabled: hasDoc) { s, _ in try pathsList(s) },
            CommandSpec("path.info", "Path Info", params: ##"{"name":str|"work"|"layer"="work"} → {name,path}"##, module: m, journal: false, enabled: hasDoc) { s, p in
                let name = p["name"]?.stringValue
                let path = try resolvePath(s, name)
                return ["name": .string(name ?? "work"), "path": pathJSON(path)]
            },
            CommandSpec("path.set", "Set Path", params: pathSetParams, module: m, enabled: hasDoc, run: pathSet),
            CommandSpec("path.delete", "Delete Path", params: ##"{"name":str|"work"="work"}"##, module: m, enabled: hasDoc, run: pathDelete),
            CommandSpec("path.transform", "Free Transform Path",
                        params: ##"{"name":str|"work"|"layer"="work","layer":id? (with layer target),"matrix":[a,b,c,d,e,f] | "quad":[[x,y]×4] (Distort/Perspective: where the frame's corners go, clockwise from top-left) | "style"|"mesh"|"warp":… (Warp, as edit.transform.warp) | "translateX":px?,"translateY":px?,"scaleX":factor?,"scaleY":factor?,"angle":degrees?,"rect":[x0,y0,x1,y1]? (the quad's or warp's frame; default = path control bounds)} (numeric transforms pivot on path bounds center)"##,
                        module: m, enabled: hasDoc, run: pathTransform),
            CommandSpec("path.clippingPath.set", "Clipping Path", params: ##"{"name":savedPathName,"flatness":0..100=0} (PSD export clipping path)"##,
                        module: m, enabled: hasDoc, run: clippingPathSet),
            CommandSpec("path.clippingPath.clear", "Clear Clipping Path", params: ##"{}"##, module: m, enabled: hasDoc, run: clippingPathClear),
            CommandSpec("path.style.copyFill", "Copy Fill", params: ##"{} (copies active shape layer fill)"##, module: m, enabled: hasShapeFill, run: copyShapeFill),
            CommandSpec("path.style.copyStroke", "Copy Complete Stroke", params: ##"{} (copies active shape layer stroke)"##, module: m, enabled: hasShapeStroke,
                        run: copyShapeStroke),
            CommandSpec("path.style.pasteFill", "Paste Fill", params: ##"{"layer":id?} (pastes copied fill onto active shape layer)"##, module: m,
                        enabled: canPasteShapeFill, run: pasteShapeFill),
            CommandSpec("path.style.pasteStroke", "Paste Complete Stroke", params: ##"{"layer":id?} (pastes copied stroke onto active shape layer)"##, module: m,
                        enabled: canPasteShapeStroke, run: pasteShapeStroke),
            CommandSpec("path.rename", "Rename Path", params: ##"{"name":str|"work"="work","to":str} (renaming the work path saves it)"##, module: m,
                        enabled: hasDoc, run: pathRename),
            // ⌘↩ / Ctrl+Enter, as in Photoshop (#306).
            CommandSpec("path.toSelection", "Make Selection from Path", shortcut: "Cmd+Enter",
                        params: ##"{"name":str|"work"|"layer"="work","feather":px=0,"antiAlias":bool=true,"mode":"replace|add|subtract|intersect"="replace"}"##,
                        module: m, enabled: hasDoc, run: pathToSelection),
            CommandSpec("select.toWorkPath", "Make Work Path", params: ##"{"tolerance":0.5..10 px=2} → {subpaths,knots}"##, module: m, enabled: hasSelection,
                        run: selectToWorkPath),
            CommandSpec("path.fill", "Fill Path",
                        params: ##"{"name":str|"work"|"layer"="work","layer":id? (pixel layer, default active),"color":"#rrggbb"=foreground,"opacity":0..100=100,"mode":"normal|multiply|…"="normal","feather":px=0,"antiAlias":bool=true}"##,
                        module: m, enabled: hasLayer, run: pathFill),
            CommandSpec("path.stroke", "Stroke Path",
                        params: ##"{"name":str|"work"|"layer"="work","layer":id? (pixel layer),"tool":"brush|pencil|eraser|backgroundEraser|cloneStamp|patternStamp|healingBrush|spotHealingBrush|historyBrush|blur|sharpen|smudge|dodge|burn|sponge|colorReplacement|mixerBrush"="brush","simulatePressure":bool=false (taper both ends when the brush follows pen pressure),"size":0.5..5000 px?,"hardness":0..1?,"opacity":0..100?,"color":"#rrggbb"=foreground} (current brush settings otherwise; tools past the Eraser run their paint.* command along the path and take its params)"##,
                        module: m, enabled: hasLayer, run: pathStroke),
            CommandSpec("layer.vectorMask.add", "Add Vector Mask", menu: ["Layer", "Vector Mask"],
                        params: ##"{"layer":id?,"path":{…}? | "name":str|"work"? (copy a document path),"hide":bool=false (Hide All = inverted)} → vector mask info. Without a path the mask reveals all."##,
                        module: m, enabled: hasLayer) { s, p in try vectorMaskAdd(s, p, fromPath: false) },
            CommandSpec("layer.vectorMask.fromPath", "Vector Mask from Current Path", menu: ["Layer", "Vector Mask"], params: ##"{"layer":id?,"name":str|"work"="work"}"##,
                        module: m, enabled: hasLayer) { s, p in try vectorMaskAdd(s, p, fromPath: true) },
            CommandSpec("layer.vectorMask.edit", "Edit Vector Mask", params: vmEditParams, module: m, enabled: hasLayer, run: vectorMaskEdit),
            CommandSpec("layer.vectorMask.delete", "Delete Vector Mask", menu: ["Layer", "Vector Mask"], params: ##"{"layer":id?}"##, module: m, enabled: hasLayer,
                        run: vectorMaskDelete),
            CommandSpec("layer.rasterize.vectorMask", "Rasterize Vector Mask", params: ##"{"layer":id?} (multiplied into the layer mask)"##, module: m,
                        enabled: hasLayer, run: vectorMaskRasterize),
            // Menu ids of Photoshop's Layer › Vector Mask / Rasterize / Combine Shapes.
            CommandSpec("layer.vectorMask.revealAll", "Vector Mask: Reveal All", params: ##"{"layer":id?}"##, module: m, enabled: hasLayer) { s, p in
                try vectorMaskAdd(s, p.setting("hide", false), fromPath: false)
            },
            CommandSpec("layer.vectorMask.hideAll", "Vector Mask: Hide All", params: ##"{"layer":id?}"##, module: m, enabled: hasLayer) { s, p in
                try vectorMaskAdd(s, p.setting("hide", true), fromPath: false)
            },
            CommandSpec("layer.vectorMask.currentPath", "Vector Mask: Current Path", params: ##"{"layer":id?,"name":str|"work"="work"}"##, module: m,
                        enabled: hasLayer) { s, p in try vectorMaskAdd(s, p, fromPath: true) },
            CommandSpec("layer.vectorMask.enabled", "Enable Vector Mask", params: ##"{"layer":id?,"enabled":bool? (default: toggle)}"##, module: m,
                        enabled: hasLayer) { s, p in try toggleVectorMask(s, p, "enabled") },
            CommandSpec("layer.vectorMask.linked", "Link Vector Mask", params: ##"{"layer":id?,"linked":bool? (default: toggle)}"##, module: m,
                        enabled: hasLayer) { s, p in try toggleVectorMask(s, p, "linked") },
            // Without `layer`, every selected shape layer.
            CommandSpec("layer.rasterize.shape", "Rasterize Shape", params: ##"{"layer":id?} (no layer: every selected shape layer)"##, module: m,
                        enabled: hasLayer) { s, p in try p["layer"] != nil ? shapeRasterize(s, p) : rasterizeSelectedShapes(s, p) },
            // With two or more shape layers selected (and no `layer`/`subpath`), these merge them into
            // the top-most one; with one, they set the operation of its components.
            CommandSpec("layer.combineShapes.unite", "Unite Shapes", params: combineParams, module: m, enabled: hasLayer) { s, p in
                try combineShapes(s, p, "combine", "Unite Shapes")
            },
            CommandSpec("layer.combineShapes.subtractFrontShape", "Subtract Front Shape", params: combineParams, module: m, enabled: hasLayer) { s, p in
                try combineShapes(s, p, "subtract", "Subtract Front Shape")
            },
            CommandSpec("layer.combineShapes.intersectShapeAreas", "Intersect Shape Areas", params: combineParams, module: m, enabled: hasLayer) { s, p in
                try combineShapes(s, p, "intersect", "Intersect Shape Areas")
            },
            CommandSpec("layer.combineShapes.excludeOverlappingShapes", "Exclude Overlapping Shapes", params: combineParams, module: m, enabled: hasLayer) { s, p in
                try combineShapes(s, p, "exclude", "Exclude Overlapping Shapes")
            },
            CommandSpec("layer.combineShapes.mergeShapeComponents", "Merge Shape Components",
                        params: ##"{"layer":id?,"tolerance":px=0.1} (bakes the path operations into plain combined outlines, traced from the exact coverage; no layer and several shape layers selected: merges them into the top-most first)"##,
                        module: m, enabled: hasLayer, run: mergeComponents),
            CommandSpec("select.convertToShape", "Convert Selection to Shape", params: ##"{"tolerance":px=2,"fill":"#rrggbb"=foreground,"name":str?} → shape.info"##,
                        module: m, enabled: hasSelection, run: selectionToShape),
            CommandSpec("layer.vectorMask.info", "Vector Mask Info", params: ##"{"layer":id?} → {layer,path,enabled,linked,density,feather}"##, module: m,
                        journal: false, enabled: hasLayer) { s, p in try vectorMaskInfo(s, try s.layerParam(p)) },
        ])
    }
}
