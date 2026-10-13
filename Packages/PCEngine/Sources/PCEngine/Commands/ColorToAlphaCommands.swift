// Port of photocraft-engine (crates/engine/src/color_to_alpha_cmds.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Filter › Other › Color to Alpha (`filter.other.colorToAlpha`, photocraft #1576): turns a chosen
// colour into transparency, unmixing it from partly covered pixels so antialiased edges keep
// their shape over any new background (PCAlgo `ColorToAlpha`).
//
// Photoshop has no such filter (GIMP and Krita do), so the id is photocraft's own; the menu item
// sits in Filter › Other after Offset. It runs through `FilterCommands.runFilter` like every
// other filter (selection, smart filters, Last Filter, one history step), which turns a
// Background layer into a normal layer ("Layer 0") first, as the erasers do, since the
// Background can't hold transparency. A layer whose transparency is locked is refused rather
// than silently getting its old alpha back.

import PCAlgo
import PCDocument

enum ColorToAlphaCommands: CommandModule {
    static let name = "color_to_alpha_cmds"

    /// The command id.
    static let id = "filter.other.colorToAlpha"

    static let white = SIMD4<Float>(1, 1, 1, 1)

    static func register(into r: inout CommandRegistry) {
        r.add(specs())
    }

    static func bad(_ msg: String) -> EngineError { .bad(id, msg) }

    /// A colour channel value: finite and clamped to 0–1 (a fallback for already validated or
    /// recorded params, e.g. a smart filter read back from a file).
    static func unit(_ v: Float, _ d: Float) -> Float { v.isFinite ? min(max(v, 0), 1) : d }

    /// Algorithm parameters (lenient: out-of-range values are clamped, unreadable ones fall back
    /// to the defaults; photocraft `params`). `run` validates strictly before it gets here.
    static func params(_ p: JSONValue) -> ColorToAlpha {
        let c = Params.color(p, "color", white)
        func num(_ k: String, _ d: Float) -> Float {
            guard case .number(let v)? = p[k] else { return d }
            return unit(Float(v), d)
        }
        return ColorToAlpha(color: SIMD4(unit(c.x, 1), unit(c.y, 1), unit(c.z, 1), 1), transparencyThreshold: num("transparencyThreshold", 0),
                            opacityThreshold: num("opacityThreshold", 1))
    }

    /// The filter runner's hook (photocraft `filters_ext::params_for` for this id), chained to the
    /// Filter Gallery's.
    static func paramsFor(_ cmd: String, _ p: JSONValue) -> AnyFilter? {
        cmd == id ? AnyFilter(params(p)) : nil
    }

    static func threshold(_ p: JSONValue, _ key: String) throws {
        guard let v = p[key] else { return }
        guard case .number(let x) = v else { throw bad("`\(key)` must be a number in 0..1") }
        if !(x.isFinite && (0...1).contains(x)) { throw bad("`\(key)` must be in 0..1") }
    }

    /// Rejects params the lenient `params` would otherwise quietly replace (photocraft `validate`).
    static func validate(_ p: JSONValue) throws {
        guard p.objectValue != nil else { throw bad("params must be a JSON object") }
        switch p["color"] {
        case nil:
            break
        case .string(let s)?:
            if Params.parseHex(s) == nil { throw bad("`color` must be \"#rrggbb\", not \"\(s)\"") }
        case .array(let a)? where (3...4).contains(a.count):
            let ok = a.allSatisfy { v in
                guard case .number(let x) = v else { return false }
                return x.isFinite && (0...1).contains(x)
            }
            if !ok { throw bad("`color` as an array must hold 3 or 4 numbers in 0..1") }
        default:
            throw bad("`color` must be \"#rrggbb\" or [r, g, b] in 0..1")
        }
        try threshold(p, "transparencyThreshold")
        try threshold(p, "opacityThreshold")
    }

    /// Menu state: a pixel layer (or smart object) in an RGB or Grayscale document whose pixels
    /// and transparency may change. The Background counts: it becomes a normal layer when run.
    static let enabled: CommandEnabled = { s, p in
        if Channels.editsChannel(s) { return "Color to Alpha works on layer pixels, not on a channel or Quick Mask" }
        if let why = FilterCommands.hasFilterableLayer(s, p) { return why }
        guard let d = s.active else { return "no document open" }
        switch d.doc.mode {
        case .rgb, .grayscale: break
        default: return "Color to Alpha needs an RGB or Grayscale document (this one is \(MultichannelCommands.debugName(d.doc.mode)))"
        }
        let l: Layer
        switch s.activeLayer() {
        case .success(let x): l = x
        case .failure(let e): return e.description
        }
        let locks = d.doc.effectiveLocks(l.id)
        if locks.pixels || locks.all { return "the layer \"\(l.name)\" is locked" }
        if locks.transparency && !d.doc.isBackground(l.id) { return "the transparency of layer \"\(l.name)\" is locked" }
        return nil
    }

    static func run(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        try validate(p)
        return try FilterCommands.runFilter(s, id, p)
    }

    static func specs() -> [CommandSpec] {
        [
            CommandSpec(id, "Color to Alpha…", menu: ["Filter", "Other"],
                        params: ##"{"color":color=#ffffff,"transparencyThreshold":0..1=0,"opacityThreshold":0..1=1}"##,
                        module: name, enabled: enabled, run: run),
        ]
    }
}
