// Port of photocraft-engine (crates/engine/src/symmetry_cmds.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Per-document painting symmetry: straight presets (PCPaint's `PresetSymmetry`) or a sampled
// Bézier path. Path samples reflect across their nearest segment, including curved paths. The
// symmetry is per-document view state: never stored in the document's paths or pixels, not a
// history step. The Brush, Pencil and Eraser strokes (`BrushCommands`) paint every mirror.

import PCDocument
import PCFoundation
import PCPaint

public enum SymmetryCommands: CommandModule {
    public static let name = "symmetry_cmds"
    static let m = "symmetry_cmds"

    /// Keep nearest-segment searches bounded for long interactive brush strokes.
    static let maxSegments = 1024
    static let samplesPerCurve = 12

    /// The active painting symmetry of a document (`DocState.view`).
    public enum Key: StateKey { public static let defaultValue: PaintingSymmetry? = nil }

    /// A symmetry path sampled into straight segments.
    public struct Axis: Hashable, Sendable {
        public var source: String
        public var segments: [[SIMD2<Double>]]

        public init(source: String, segments: [[SIMD2<Double>]]) {
            self.source = source
            self.segments = segments
        }

        public static func fromPath(_ source: String, _ path: VectorPath) throws -> Axis {
            var segments: [[SIMD2<Double>]] = []
            for subpath in path.subpaths {
                for seg in subpath.segments where seg.count == 4 {
                    let (a, b, c, d) = (seg[0], seg[1], seg[2], seg[3])
                    let samples = a == b && c == d ? 1 : samplesPerCurve
                    var previous = SIMD2(a.x, a.y)
                    for step in 1...samples {
                        if segments.count >= maxSegments { throw EngineError.other("symmetry path is too complex") }
                        let t = Double(step) / Double(samples)
                        let u = 1 - t
                        let next = SIMD2(u * u * u * a.x + 3 * u * u * t * b.x + 3 * u * t * t * c.x + t * t * t * d.x,
                                         u * u * u * a.y + 3 * u * u * t * b.y + 3 * u * t * t * c.y + t * t * t * d.y)
                        if ![previous.x, previous.y, next.x, next.y].allSatisfy({ $0.isFinite && abs($0) <= 1_000_000 }) {
                            throw EngineError.other("symmetry path coordinates must be finite and within canvas limits")
                        }
                        if previous != next { segments.append([previous, next]) }
                        previous = next
                    }
                }
            }
            if segments.isEmpty { throw EngineError.other("symmetry path needs at least one nonzero segment") }
            return Axis(source: source, segments: segments)
        }

        public func reflect(_ point: StrokePoint) -> StrokePoint {
            var best: (Double, SIMD2<Double>, SIMD2<Double>)?
            for s in segments where s.count == 2 {
                let (a, b) = (s[0], s[1])
                let vx = b.x - a.x, vy = b.y - a.y
                let len2 = vx * vx + vy * vy
                if len2 <= Double.ulpOfOne { continue }
                let t = min(max(((point.x - a.x) * vx + (point.y - a.y) * vy) / len2, 0), 1)
                let q = SIMD2(a.x + vx * t, a.y + vy * t)
                let dist2 = (point.x - q.x) * (point.x - q.x) + (point.y - q.y) * (point.y - q.y)
                if best.map({ dist2 < $0.0 }) ?? true { best = (dist2, q, SIMD2(vx, vy)) }
            }
            guard let (_, q, tangent) = best else { return point }
            let len2 = tangent.x * tangent.x + tangent.y * tangent.y
            let dx = point.x - q.x, dy = point.y - q.y
            let along = (dx * tangent.x + dy * tangent.y) / len2
            var mirrored = point
            mirrored.x = q.x + 2 * along * tangent.x - dx
            mirrored.y = q.y + 2 * along * tangent.y - dy
            return mirrored
        }

        public func reflectPoints(_ points: [StrokePoint]) -> [StrokePoint] { points.map(reflect) }

        /// A stroke lying exactly on the symmetry path needs only one render pass. Rendering its
        /// reflected copy would compound semi-transparent paint along the axis.
        public static func hasDistinctMirror(_ points: [StrokePoint], _ reflected: [StrokePoint]) -> Bool {
            zip(points, reflected).contains { abs($0.x - $1.x) > 1e-6 || abs($0.y - $1.y) > 1e-6 }
        }
    }

    /// Per-document painting tool state, never stored in the document's paths or pixels.
    public enum PaintingSymmetry: Hashable, Sendable {
        case path(Axis)
        case preset(PresetSymmetry)

        public var preset: PresetSymmetry? {
            if case .preset(let p) = self { return p }
            return nil
        }

        public var pathSource: String? {
            if case .path(let a) = self { return a.source }
            return nil
        }

        public var mirrorCount: Int {
            switch self {
            case .path: 1
            case .preset(let p): p.mirrorCount
            }
        }

        public func reflectedPasses(_ points: [StrokePoint]) -> [[StrokePoint]] {
            switch self {
            case .path(let axis): [axis.reflectPoints(points)]
            case .preset(let p): p.reflectedPasses(points)
            }
        }

        public var inspect: JSONValue {
            switch self {
            case .path(let axis): ["mode": "path", "source": .string(axis.source), "segments": .int(axis.segments.count)]
            case .preset(let p): ["mode": .string(p.mode.id), "center": [.number(p.center.x), .number(p.center.y)], "rotation": .number(p.rotation)]
            }
        }
    }

    static func setPreset(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let fail = EngineError.other("symmetry requires a valid mode, a finite [x,y] centre and a finite rotation")
        guard let st = s.active else { throw EngineError.noDocument }
        guard let mode = p["mode"]?.stringValue.flatMap(SymmetryMode.init(id:)) else { throw fail }
        let center: SIMD2<Double>
        if let v = p["center"] {
            guard let a = v.arrayValue, a.count == 2, let x = a[0].doubleValue, let y = a[1].doubleValue else { throw fail }
            center = SIMD2(x, y)
        } else {
            center = SIMD2(Double(st.doc.size.width) / 2, Double(st.doc.size.height) / 2)
        }
        let rotation: Double
        if let v = p["rotation"] {
            guard let r = v.doubleValue else { throw fail }
            rotation = r
        } else {
            rotation = 0
        }
        guard let preset = PresetSymmetry(mode, center: center, rotation: rotation) else { throw fail }
        let symmetry = PaintingSymmetry.preset(preset)
        try s.updateActive { $0.view[Key.self] = symmetry }
        return symmetry.inspect
    }

    static func activePath(_ s: Session, _ name: String) throws -> VectorPath {
        guard let st = s.active else { throw EngineError.noDocument }
        if name == "work" {
            guard let w = st.doc.workPath else { throw EngineError.other("no work path") }
            return w
        }
        if name == "layer" {
            guard let id = st.activeLayer else { throw EngineError.other("no active layer") }
            guard let layer = st.doc.layer(id) else { throw EngineError.noLayer(id) }
            if case .shape(let shape) = layer.content { return shape.path }
            guard let mask = layer.vectorMask else { throw EngineError.other("active layer has no vector path") }
            return mask.path
        }
        guard let path = st.doc.paths.first(where: { $0.name == name }) else { throw EngineError.other("no path named `\(name)`") }
        return path.path
    }

    static func enable(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let name = p["name"]?.stringValue ?? "work"
        let axis = try Axis.fromPath(name, try activePath(s, name))
        let count = axis.segments.count
        try s.updateActive { $0.view[Key.self] = .path(axis) }
        return ["enabled": true, "source": .string(name), "segments": .int(count)]
    }

    public static func register(into r: inout CommandRegistry) {
        r.hooks.documentInspectors.append { st, o in o["symmetry"] = st.view[Key.self]?.inspect ?? .null }
        r.add([
            CommandSpec("paint.setSymmetry", "Set Painting Symmetry",
                        params: #"{"mode":"vertical|horizontal|dual|diagonal","center":[x,y]?,"rotation":degrees=0}"#,
                        module: m, enabled: Pre.hasDoc, run: setPreset),
            CommandSpec("paint.symmetryFromPath", "Make Symmetry Path",
                        params: #"{"name":"work"|"layer"|savedPathName="work"} — mirror Brush, Pencil and Eraser strokes across the path"#,
                        module: m, enabled: Pre.hasDoc, run: enable),
            CommandSpec("paint.symmetryDisable", "Disable Painting Symmetry", params: "{}", module: m,
                        enabled: { s, _ in s.active?.view[Key.self] == nil ? "no active painting symmetry" : nil }) { s, _ in
                try s.updateActive { $0.view[Key.self] = nil }
                return ["enabled": false]
            },
        ])
    }
}
