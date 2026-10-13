// Port of photocraft-engine (crates/engine/src/pattern_fill_cmds.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Editing a Pattern Fill layer: Photoshop's Pattern Fill dialog (pattern, Angle, Scale, Link with
// Layer, Snap to Origin) commits one undoable content edit, independent of the layer's masks.
// `preview` gives the dialog the document as OK would leave it.

import Foundation
import PCDocument
import PCFoundation

enum PatternFillCommands: CommandModule {
    static let name = "pattern_fill_cmds"
    static let m = name
    static let set = "layer.fill.pattern.set"
    /// Layer › New Fill Layer › Pattern… (`pattern_cmds`).
    static let create = "layer.newFillLayer.pattern"

    /// Photoshop's Scale range in the Pattern Fill dialog (percent).
    static let scaleRange: ClosedRange<Double> = 1...1000
    /// Largest phase (origin offset) accepted, in pixels.
    static let maxPhase = 1.0e7

    static func register(into r: inout CommandRegistry) {
        r.add(specs())
    }

    static func bad(_ msg: String) -> EngineError { .bad(set, msg) }

    /// A number as Rust's `Display` prints an `f64` (`1000`, not `1000.0`).
    static func rustNumber(_ v: Double) -> String {
        v == v.rounded() && abs(v) < 1e15 ? String(Int64(v)) : "\(v)"
    }

    /// The pattern fill `p` asks for, each param optional and defaulting to `base`. Returns the new
    /// fill and the pattern to copy into the document (when `pattern` was given).
    static func edited(_ s: Session, _ base: Fill, _ p: JSONValue) throws -> (Fill, Pattern?) {
        guard case .pattern(var f) = base else { throw bad("the target must be a Pattern Fill layer") }
        func num(_ k: String, _ range: ClosedRange<Double>) throws -> Float? {
            guard let v = p[k], v != .null else { return nil }
            guard let x = v.doubleValue, x.isFinite, range.contains(x) else {
                throw bad("`\(k)` must be a number within \(rustNumber(range.lowerBound))..\(rustNumber(range.upperBound))")
            }
            return Float(x)
        }
        var pat: Pattern?
        if let v = p["pattern"], v != .null {
            guard let key = v.stringValue, !key.isEmpty else { throw bad("`pattern` is a pattern id or name") }
            guard let found = PatternCommands.resolve(s, key) else { throw bad("no pattern \"\(key)\" (see pattern.list)") }
            pat = found
        }
        if let v = try num("scale", scaleRange) { f.scale = v / 100 }
        if let v = try num("angle", -180...180) { f.angle = v }
        if let v = p["link"], v != .null {
            guard let b = v.boolValue else { throw bad("`link` is true or false") }
            f.link = b
        }
        if let v = p["phase"], v != .null {
            guard let a = v.arrayValue, a.count == 2 else { throw bad("`phase` is [x, y]") }
            func c(_ i: Int) -> Float? {
                guard let x = a[i].doubleValue, x.isFinite, abs(x) <= maxPhase else { return nil }
                return Float(x)
            }
            guard let x = c(0), let y = c(1) else { throw bad("`phase` needs finite coordinates within ±\(rustNumber(maxPhase))") }
            f.phase = SIMD2(x, y)
        }
        if let pat {
            f.name = pat.name
            f.id = pat.id
        }
        return (.pattern(f), pat)
    }

    /// The target layer and the fill `p` gives it, checked against the active document.
    static func target(_ s: Session, _ p: JSONValue) throws -> (LayerId, Fill, Fill, Pattern?) {
        if p.objectValue == nil || (p["layer"].map { $0.uint64Value == nil } ?? false) {
            throw bad("params must be an object and layer an unsigned id")
        }
        guard let st = s.active else { throw EngineError.noDocument }
        if let document = p["document"], document.uint64Value != st.doc.id.rawValue { throw bad("the target document is no longer active") }
        let id = try s.layerParam(p)
        guard let layer = st.doc.layer(id) else { throw EngineError.noLayer(id) }
        guard case .fill(let original) = layer.content, case .pattern = original else { throw bad("the target must be a Pattern Fill layer") }
        let (fill, pat) = try edited(s, original, p)
        return (id, original, fill, pat)
    }

    static func run(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let (id, original, fill, pat) = try target(s, p)
        if fill != original {
            guard let st = s.active else { throw EngineError.noDocument }
            try LayerOps.checkPixelsUnlocked(st.doc, id)
            try s.edit("Pattern Fill") { doc, _ in
                if let pat { PatternCommands.ensureInDoc(&doc, pat) }
                guard doc.layer(id) != nil else { throw EngineError.noLayer(id) }
                doc.updateLayer(id) { $0.content = .fill(fill) }
            }
        }
        return info(id, fill)
    }

    static func info(_ layer: LayerId, _ fill: Fill) -> JSONValue {
        guard case .pattern(let f) = fill else { return ["layer": .id(layer)] }
        return ["layer": .id(layer), "pattern": .string(f.id), "scale": .float(f.scale * 100), "angle": .float(f.angle), "link": .bool(f.link),
                "phase": [.float(f.phase.x), .float(f.phase.y)]]
    }

    /// photocraft `preview`: the active document as `set` or `create` with `p` would leave it,
    /// without a history step (the Pattern Fill dialog's live preview, so it shows exactly what OK
    /// commits).
    static func preview(_ s: Session, _ cmd: String, _ p: JSONValue) throws -> Document {
        guard let st = s.active else { throw EngineError.noDocument }
        var doc = st.doc
        switch cmd {
        case set:
            let (id, _, fill, pat) = try target(s, p)
            if let pat { PatternCommands.ensureInDoc(&doc, pat) }
            guard doc.layer(id) != nil else { throw EngineError.noLayer(id) }
            doc.updateLayer(id) { $0.content = .fill(fill) }
        case create:
            let pat = try PatternCommands.resolveParam(s, create, p)
            var active = st.activeLayer
            try PatternCommands.insertFillLayer(&doc, &active, pat, p)
        default:
            throw EngineError.bad(cmd, "no Pattern Fill preview for this command")
        }
        return doc
    }

    static func specs() -> [CommandSpec] {
        [
            CommandSpec(set, "Pattern Fill…",
                        params: ##"{"layer":id? (default active; a Pattern Fill layer),"document":id? (reject a stale dialog),"pattern":id|name?,"scale":1..1000?,"angle":-180..180?,"link":bool?,"phase":[x,y]? (Snap to Origin: [0,0])}; omitted values keep the layer's"##,
                        module: m, enabled: Pre.hasDoc, run: run),
        ]
    }
}
