// Port of photocraft-engine (crates/engine/src/magnetic_cmds.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Magnetic Lasso: a selection border that snaps to edges between fastening points. Between two
// points the border is the cheapest 8-connected pixel path where pixels on a strong, well-localised
// edge are cheap — the "live wire" of Mortensen & Barrett (SIGGRAPH 1995), with non-maximum
// suppression for the edge-centre term and a corridor around the pointer's path. The interactive
// tool traces live through an `EdgeSource` and commits with `"trace": false`; given fastening
// points alone, `select.magneticLasso` traces the whole border itself. The tracer is PCAlgo's
// `MagneticLasso` (photocraft-algo magnetic.rs).

import Foundation
import PCAlgo
import PCDocument
import PCFoundation

public enum MagneticCommands: CommandModule {
    public static let name = "magnetic_cmds"
    static let m = "magnetic_cmds"
    static let cmd = "select.magneticLasso"
    /// Most points one command takes.
    public static let maxPoints = 100_000
    /// Longest border one command traces (px, measured along the fastening points).
    static let maxLength = 200_000.0

    /// Detection settings: the Magnetic Lasso options bar (PCAlgo `MagneticLasso.Settings`).
    public typealias Settings = MagneticLasso.Settings
    /// Edge tracing over one image, caching the pixels it has read (PCAlgo `MagneticLasso.Tracer`).
    public typealias Tracer = MagneticLasso.Tracer

    public static func register(into r: inout CommandRegistry) {
        r.add(CommandSpec(cmd, "Magnetic Lasso",
                          params: #"{"points":[[x,y],…] (≥3 fastening points in order; with trace=false, the finished outline),"width":1..256=10 (px: follows edges this close to the points),"contrast":1..100=10 (%: weaker edges are ignored),"close":"magnetic|straight"="magnetic" (how the last point joins the first),"trace":bool=true,"mode":"replace|add|subtract|intersect"="replace","antiAlias":bool=true,"feather":0..1000=0 (px)}"#,
                          module: m, enabled: Pre.hasDoc, run: magneticLasso))
    }

    // MARK: Edge source

    /// The pixels the Magnetic Lasso follows: the active layer's when it is a pixel layer, else
    /// the composite. A snapshot of one document revision, read lazily and cached.
    public final class EdgeSource {
        let doc: Document
        let layer: LayerId?
        let revision: UInt64
        let renderer: EngineRenderer
        public private(set) var tracer: Tracer

        /// For the session's active document; nil without one.
        public init?(_ s: Session) {
            guard let d = s.active else { return nil }
            doc = d.doc
            layer = MagneticCommands.pixelLayer(d)
            revision = d.revision
            renderer = s.services.renderer
            tracer = Tracer(bounds: d.doc.bounds)
        }

        /// Whether this still shows the session's active document, layer and revision.
        public func isCurrent(_ s: Session) -> Bool {
            guard let d = s.active else { return false }
            return d.doc.id == doc.id && d.revision == revision && MagneticCommands.pixelLayer(d) == layer
        }

        public var docId: DocId { doc.id }

        /// Where a fastening point near `p` goes (see `Tracer.snap`).
        public func snap(_ p: SIMD2<Double>, _ s: Settings) -> SIMD2<Double>? {
            tracer.snap(fetch, p, s)
        }

        /// The border from `from` to `to` along the edges near `guide` (see `Tracer.trace`).
        public func trace(_ from: SIMD2<Double>, _ to: SIMD2<Double>, guide: [SIMD2<Double>], _ s: Settings) -> [SIMD2<Double>] {
            tracer.trace(fetch, from: from, to: to, guide: guide, s)
        }

        /// Straight RGBA8 pixels of `r` from the layer, or the composite without one.
        func fetch(_ r: PixelRect) -> [SIMD4<UInt8>] {
            if let surf = layer.flatMap({ doc.layer($0) })?.surface { return Selection.rgba8Image(surf, area: r) }
            return (try? renderer.render(doc, region: r).px.map(SelectionCommands.q8)) ?? []
        }
    }

    /// The active layer when it has pixels of its own.
    static func pixelLayer(_ d: DocState) -> LayerId? {
        guard let id = d.activeLayer, d.doc.layer(id)?.surface != nil else { return nil }
        return id
    }

    // MARK: Command

    static func bad(_ msg: String) -> EngineError { .bad(cmd, msg) }

    static func points(_ p: JSONValue) throws -> [SIMD2<Double>] {
        guard let a = p["points"]?.arrayValue else { throw bad("`points` must be [[x, y], …]") }
        if a.count > maxPoints { throw bad("at most \(maxPoints) points") }
        return try a.map { q in
            guard let xy = q.arrayValue, xy.count == 2, let x = xy[0].doubleValue, let y = xy[1].doubleValue, x.isFinite, y.isFinite else {
                throw bad("bad point \(q.serialized()) (want [x, y])")
            }
            return SIMD2(x, y)
        }
    }

    /// A number in `lo...hi`, or `d` when absent.
    static func number(_ p: JSONValue, _ key: String, _ d: Double, _ lo: Double, _ hi: Double, _ range: String) throws -> Double {
        guard let v = p[key] else { return d }
        guard let x = v.doubleValue, x >= lo, x <= hi else { throw bad("`\(key)` must be a number in \(range) (got \(v.serialized()))") }
        return x
    }

    static func magneticLasso(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let pts = try points(p)
        if pts.count < 3 { throw bad("needs at least 3 points") }
        var trace = true
        if let v = p["trace"] {
            guard let b = v.boolValue else { throw bad("`trace` must be true or false") }
            trace = b
        }
        let outline: [SIMD2<Double>]
        if trace {
            let width = try number(p, "width", 10, MagneticLasso.widthRange.0, MagneticLasso.widthRange.1, "1..256")
            let contrast = try number(p, "contrast", 10, 1, 100, "1..100")
            let straight: Bool
            switch p["close"] {
            case nil, .string("magnetic")?: straight = false
            case .string("straight")?: straight = true
            default: throw bad("`close` must be \"magnetic\" or \"straight\"")
            }
            let settings = Settings(width: width, contrast: Float(contrast / 100))
            guard let src = EdgeSource(s) else { throw EngineError.noDocument }
            outline = try traceBorder(src, pts, settings, straight: straight)
        } else {
            outline = pts
        }
        let polygon = outline.map { SIMD2(Float($0.x), Float($0.y)) }
        let r = try SelectionCommands.polygonSelection(s, cmd, "Magnetic Lasso", polygon, p)
        return r.setting("points", .int(outline.count))
    }

    /// The closed border through the fastening points, each snapped to the nearest prominent edge
    /// first. The last point joins the first along the edges, or straight with `straight`.
    public static func traceBorder(_ src: EdgeSource, _ pts: [SIMD2<Double>], _ settings: Settings, straight: Bool) throws -> [SIMD2<Double>] {
        let b = src.tracer.bounds
        var ring = pts.map { q in SIMD2(min(max(q.x, Double(b.x0)), Double(b.x1)), min(max(q.y, Double(b.y0)), Double(b.y1))) }
        if let first = ring.first { ring.append(first) }
        if MagneticLasso.length(ring) > maxLength { throw bad("the border is longer than \(Int(maxLength)) px") }
        ring.removeLast()
        let anchors = ring.compactMap { src.snap($0, settings) }
        guard let first = anchors.first else { throw EngineError.other("the document has no pixels") }
        var out = [first]
        for i in 0..<max(anchors.count - 1, 0) {
            out += src.trace(anchors[i], anchors[i + 1], guide: [], settings).dropFirst()
        }
        if !straight, let last = anchors.last {
            out += src.trace(last, first, guide: [], settings).dropFirst()
            // The ring ends where it started.
            out.removeLast()
        }
        return out
    }
}
