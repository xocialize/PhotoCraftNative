// Port of photocraft-engine (crates/engine/src/sampler_cmds.rs, and lib.rs `Session::edit`'s Color Sampler bookkeeping and `take_samplers_removed`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Color Sampler points (#1046): numbered colour readings pinned to canvas pixels and listed in the
// Info panel, so a fixed position can be compared instead of chasing the live pointer. Points are
// per-document view state: they belong to their document, are discarded when it closes, and are
// not saved. Placing, moving and removing them changes no pixels and adds no History step, so they
// are not journaled. Each point reads one composite pixel (no averaging). A canvas-size change
// (crop, Canvas Size, Image Size, rotation) moves the points with their pixels (`SamplerMap`) and
// drops the ones that land outside the new canvas.

import PCDocument
import PCFoundation

public enum SamplerCommands: CommandModule {
    public static let name = "sampler_cmds"
    static let m = "sampler_cmds"

    /// Photoshop's Color Sampler limit: at most 10 points per document.
    public static let maxSamplers = 10

    /// A document's sample points (`DocState.view`), in pixel coordinates.
    public enum Key: StateKey { public static let defaultValue: [SIMD2<Double>] = [] }

    /// Points dropped by canvas-size changes since the last `takeRemoved` (for the status message).
    enum RemovedKey: StateKey { static let defaultValue = 0 }

    /// The points dropped by canvas changes since the last call (photocraft
    /// `Session::take_samplers_removed`).
    public static func takeRemoved(_ s: Session) -> Int {
        let n = s.state[RemovedKey.self]
        s.state[RemovedKey.self] = 0
        return n
    }

    static func bad(_ cmd: String, _ msg: String) -> EngineError { .bad(cmd, msg) }

    /// Naive device CMYK (no ICC profile), in percent, as the Info panel shows it.
    public static func deviceCMYK(_ r: Float, _ g: Float, _ b: Float) -> [Int] {
        let k = 1 - max(max(r, g), b)
        func f(_ v: Float) -> Float { k >= 1 ? 0 : (1 - v - k) / (1 - k) }
        return [f(r), f(g), f(b), k].map { Int(($0 * 100).rounded()) }
    }

    /// The Info-panel values for a sample point at document pixel `pos`: composite RGB 0–255 and
    /// naive device CMYK percentages. One composite pixel, no averaging.
    static func readout(_ doc: Document, _ pos: SIMD2<Double>, _ renderer: EngineRenderer) -> ([Int], [Int]) {
        let c = SampleCommands.sampleColor(doc, nil, pos.x, pos.y, 1, .all, renderer: renderer)
        func q(_ v: Float) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return ([q(c.x), q(c.y), q(c.z)], deviceCMYK(c.x, c.y, c.z))
    }

    /// One point as the list command reports it.
    static func pointJSON(_ doc: Document, _ index: Int, _ pos: SIMD2<Double>, _ renderer: EngineRenderer) -> JSONValue {
        let (rgb, cmyk) = readout(doc, pos, renderer)
        return ["index": .int(index), "number": .int(index + 1), "position": [.number(pos.x), .number(pos.y)],
                "rgb": .array(rgb.map { .int($0) }), "cmyk": .array(cmyk.map { .int($0) })]
    }

    static func coord(_ cmd: String, _ p: JSONValue, _ key: String) throws -> Double {
        guard let v = p[key]?.doubleValue, v.isFinite else { throw bad(cmd, "`\(key)` must be a finite number (document pixels)") }
        return v
    }

    /// The pixel a point at document coordinate `(x, y)` sits on, if it is inside the canvas.
    /// Whole pixels only: the click's fractional position floors to the pixel it lands on.
    static func pixel(_ doc: Document, _ x: Double, _ y: Double) -> SIMD2<Double>? {
        let (px, py) = (x.rounded(.down), y.rounded(.down))
        guard px >= Double(Int32.min), px <= Double(Int32.max), py >= Double(Int32.min), py <= Double(Int32.max) else { return nil }
        return doc.bounds.contains(x: Int32(px), y: Int32(py)) ? SIMD2(px, py) : nil
    }

    static func indexParam(_ cmd: String, _ p: JSONValue) throws -> Int {
        guard let n = p["index"]?.uint64Value, n <= UInt64(Int.max) else { throw bad(cmd, "pass `index` (0-based)") }
        return Int(n)
    }

    /// Apply a Color Sampler change to the active document: view state, so no history step and
    /// no pixels. Bumps the revision (keeping a clean document clean) so UIs refresh.
    static func change<R>(_ s: Session, _ body: (inout DocState) throws -> R) throws -> R {
        try s.updateActive { st in
            let r = try body(&st)
            Session.noEditRevision(&st)
            return r
        }
    }

    static func add(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "view.colorSamplers.add"
        let x = try coord(cmd, p, "x"), y = try coord(cmd, p, "y")
        let renderer = s.services.renderer
        return try change(s) { st in
            guard let pos = pixel(st.doc, x, y) else { throw EngineError.other("the sample point is outside the canvas") }
            if st.view[Key.self].count >= maxSamplers {
                throw EngineError.other("Color Sampler limit reached: at most \(maxSamplers) points per document")
            }
            st.view[Key.self].append(pos)
            let i = st.view[Key.self].count - 1
            return ["index": .int(i), "count": .int(st.view[Key.self].count), "point": pointJSON(st.doc, i, pos, renderer)]
        }
    }

    static func movePoint(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "view.colorSamplers.move"
        let i = try indexParam(cmd, p)
        let x = try coord(cmd, p, "x"), y = try coord(cmd, p, "y")
        let renderer = s.services.renderer
        return try change(s) { st in
            let n = st.view[Key.self].count
            if i >= n { throw bad(cmd, "no sample point \(i) (the document has \(n))") }
            guard let pos = pixel(st.doc, x, y) else { throw EngineError.other("the sample point is outside the canvas") }
            st.view[Key.self][i] = pos
            return ["index": .int(i), "point": pointJSON(st.doc, i, pos, renderer)]
        }
    }

    static func delete(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "view.colorSamplers.delete"
        let i = try indexParam(cmd, p)
        return try change(s) { st in
            let n = st.view[Key.self].count
            if i >= n { throw bad(cmd, "no sample point \(i) (the document has \(n))") }
            st.view[Key.self].remove(at: i)
            return ["deleted": 1, "remaining": .int(st.view[Key.self].count)]
        }
    }

    static func clear(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        try change(s) { st in
            let n = st.view[Key.self].count
            st.view[Key.self] = []
            return ["deleted": .int(n), "remaining": 0]
        }
    }

    static func list(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        guard let st = s.active else { throw EngineError.noDocument }
        let pts = st.view[Key.self]
        return ["max": .int(maxSamplers), "samplers": .array(pts.enumerated().map { pointJSON(st.doc, $0, $1, s.services.renderer) })]
    }

    /// After a committed step (photocraft `Session::edit`): a canvas-size change moves the points
    /// with their pixels and drops the ones that land outside the new canvas. A mapped edit
    /// (`SamplerMap`) gives the exact map; any other size change drops whatever is now outside.
    static func afterCommit(_ s: Session, _ index: Int, _ before: Document) {
        let map = SamplerMap.take(s)
        guard index >= 0, index < s.documents.count else { return }
        let removed: Int = (try? s.updateDocument(at: index) { st -> Int in
            let pts = st.view[Key.self]
            if pts.isEmpty { return 0 }
            let bounds = st.doc.bounds
            func inside(_ q: SIMD2<Double>) -> Bool {
                let (x, y) = (q.x.rounded(.down), q.y.rounded(.down))
                guard x >= Double(Int32.min), x <= Double(Int32.max), y >= Double(Int32.min), y <= Double(Int32.max) else { return false }
                return bounds.contains(x: Int32(x), y: Int32(y))
            }
            var kept: [SIMD2<Double>]
            if let a = map {
                kept = pts.map { a.apply($0) }.filter(inside)
            } else if st.doc.size != before.size {
                kept = pts.filter(inside)
            } else {
                return 0
            }
            st.view[Key.self] = kept
            return pts.count - kept.count
        }) ?? 0
        if removed > 0 { s.state[RemovedKey.self] += removed }
    }

    public static func register(into r: inout CommandRegistry) {
        r.hooks.afterCommit.append { s, i, before in afterCommit(s, i, before) }
        // A map left by a canvas command whose edit failed must not move the points of a later
        // edit (photocraft takes it at the start of every edit).
        r.hooks.before.append { s, _, _ in
            if s.depth == 0 { _ = SamplerMap.take(s) }
            return Optional<JSONValue>.none
        }
        r.add([
            CommandSpec("view.colorSamplers.add", "Add Color Sampler",
                        params: #"{"x":f64,"y":f64} → the new point {index, number, position, rgb, cmyk}; errors at the 10-point limit or off the canvas"#,
                        module: m, journal: false, enabled: Pre.hasDoc, run: add),
            CommandSpec("view.colorSamplers.move", "Move Color Sampler", params: #"{"index":n,"x":f64,"y":f64}"#, module: m, journal: false,
                        enabled: Pre.hasDoc, run: movePoint),
            CommandSpec("view.colorSamplers.delete", "Delete Color Sampler", params: #"{"index":n}"#, module: m, journal: false,
                        enabled: Pre.hasDoc, run: delete),
            CommandSpec("view.colorSamplers.clear", "Clear Color Samplers", params: "{}", module: m, journal: false, enabled: Pre.hasDoc, run: clear),
            CommandSpec("view.colorSamplers.list", "Color Samplers", params: #"{} → {max, samplers:[{index, number, position, rgb, cmyk}]}"#,
                        module: m, journal: false, enabled: Pre.hasDoc, run: list),
        ])
    }
}
