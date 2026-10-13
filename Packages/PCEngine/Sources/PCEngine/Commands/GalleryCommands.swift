// Port of photocraft-engine (crates/engine/src/gallery_cmds.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Filter › Filter Gallery… (`filter.filterGallery`) and one command per gallery filter
// (`filter.gallery.<key>`, not in menus).
//
// `filter.filterGallery {effects:[{filter, params, visible}]}` applies a stack of effect layers in
// order (the gallery dialog's effect list, bottom to top). Like every filter it goes through
// `FilterCommands.runFilter`: selection, smart objects (recorded as a smart filter), history,
// channels and `filter.lastFilter` all work. The foreground/background colours the Sketch filters
// read are recorded as explicit params, so smart filters re-render identically. The 47 effects
// are PCAlgo's `FilterGallery`.

import PCAlgo
import PCDocument

enum GalleryCommands: CommandModule {
    static let name = "gallery_cmds"

    static let galleryId = "filter.filterGallery"
    static let prefix = "filter.gallery."

    static func register(into r: inout CommandRegistry) {
        r.add(specs())
    }

    // MARK: Params

    /// Straight RGBA colour from `[r, g, b(, a)]` (0–1) or `#rrggbb` (photocraft `colour`).
    static func colour(_ v: JSONValue?) -> SIMD4<Float>? {
        switch v {
        case .array(let a)? where a.count >= 3:
            func c(_ j: Int, _ d: Float) -> Float { j < a.count ? a[j].doubleValue.map { Float($0) } ?? d : d }
            return SIMD4(c(0, 0), c(1, 0), c(2, 0), c(3, 1))
        case .string(let h)? where h.utf8.count == 7 && h.hasPrefix("#"):
            let b = Array(h.utf8)
            func ch(_ j: Int) -> Float {
                guard j + 2 <= b.count, let v = UInt8(String(decoding: b[j..<j + 2], as: UTF8.self), radix: 16) else { return 0 }
                return Float(v) / 255
            }
            return SIMD4(ch(1), ch(3), ch(5), 1)
        default:
            return nil
        }
    }

    /// The gallery filter a `filter.gallery.<key>` id names.
    static func galleryFilter(_ id: String) -> GalleryFilter? {
        guard id.hasPrefix(prefix) else { return nil }
        return GalleryFilter.from(key: String(id.dropFirst(prefix.count)))
    }

    /// One effect from its params object; `fallback` supplies colours not given per effect
    /// (photocraft `effect_from_json`).
    static func effectFromJSON(_ filter: GalleryFilter, _ p: JSONValue, _ fallback: JSONValue) -> GalleryEffect {
        var e = GalleryEffect(filter)
        for prm in filter.params {
            guard let v = p[prm.key] else { continue }
            switch (prm.kind, v) {
            case (.choice, .string(let name)):
                e.setChoice(prm.key, name)
            case (_, .bool(let b)):
                e.set(prm.key, b ? 1 : 0)
            case (_, .number(let n)):
                e.set(prm.key, Float(n))
            default:
                break
            }
        }
        func pick(_ k: String) -> SIMD4<Float>? { colour(p[k]) ?? colour(fallback[k]) }
        if let c = pick("foreground") { e.foreground = c }
        if let c = pick("background") { e.background = c }
        if let c = pick("glowColor") { e.color = c }
        return e
    }

    /// An entry's params: `params` when it is an object, else the entry itself.
    static func entryParams(_ item: JSONValue) -> JSONValue {
        if let q = item["params"], q.objectValue != nil { return q }
        return item
    }

    /// The effect stack of a `filter.filterGallery` params object (photocraft `effects_from_json`).
    /// Entries are `{"filter": "<key>", "params": {...}, "visible": bool}` (params may also sit
    /// beside `filter`); hidden entries are skipped. The error is the message.
    static func effectsFromJSON(_ p: JSONValue) -> Result<[GalleryEffect], EngineError> {
        guard let list = p["effects"]?.arrayValue else { return .success([]) }
        if list.count > 32 { return .failure(.other("too many effects in filterGallery stack (max 32)")) }
        var out: [GalleryEffect] = []
        for (k, item) in list.enumerated() {
            if item["visible"]?.boolValue == false { continue }
            guard let key = item["filter"]?.stringValue else { return .failure(.other("effect \(k): missing `filter`")) }
            guard let f = GalleryFilter.from(key: key) else { return .failure(.other("effect \(k): unknown gallery filter `\(key)`")) }
            out.append(effectFromJSON(f, entryParams(item), p))
        }
        return .success(out)
    }

    /// Algorithm parameters for the ids this module owns (photocraft `params_for`).
    static func paramsFor(_ id: String, _ p: JSONValue) -> AnyFilter? {
        if id == galleryId {
            let effects = (try? effectsFromJSON(p).get()) ?? []
            return AnyFilter(FilterGallery(effects: effects))
        }
        guard let f = galleryFilter(id) else { return nil }
        return AnyFilter(FilterGallery(effects: [effectFromJSON(f, p, .null)]))
    }

    // MARK: Validation

    /// An unknown choice name or a wrong-typed choice is a bad-params error, for one gallery filter
    /// or each effect of a `filter.filterGallery` stack (photocraft `validate_params`, reached from
    /// `filters::validate_params` for ids without a field table). Checked only for new
    /// invocations; stored smart filters keep decoding tolerantly.
    static func validateParams(_ id: String, _ p: JSONValue) throws {
        if id == galleryId {
            for (k, item) in (p["effects"]?.arrayValue ?? []).enumerated() {
                guard let key = item["filter"]?.stringValue, let f = GalleryFilter.from(key: key) else { continue }
                if let m = checkChoices(f, entryParams(item)) { throw EngineError.bad(id, "effect \(k): \(m)") }
            }
            return
        }
        guard let f = galleryFilter(id) else { return }
        if let m = checkChoices(f, p) { throw EngineError.bad(id, m) }
    }

    /// The first choice param of `p` that names no choice (photocraft `check_choices`).
    static func checkChoices(_ f: GalleryFilter, _ p: JSONValue) -> String? {
        for prm in f.params {
            guard let v = p[prm.key], case .choice(let names) = prm.kind else { continue }
            let ok: Bool
            switch v {
            case .string(let name): ok = names.contains { asciiCaseless($0, name) }
            // A choice index, clamped as the dialog stores it.
            case .number: ok = true
            default: ok = false
            }
            if !ok { return "`\(prm.key)` must be one of \(names.joined(separator: "|"))" }
        }
        return nil
    }

    /// Rust's `eq_ignore_ascii_case`.
    static func asciiCaseless(_ a: String, _ b: String) -> Bool {
        func lower(_ c: UInt8) -> UInt8 { (65...90).contains(c) ? c + 32 : c }
        let x = Array(a.utf8), y = Array(b.utf8)
        return x.count == y.count && zip(x, y).allSatisfy { lower($0) == lower($1) }
    }

    /// Whether the command reads the foreground/background colours (photocraft `uses_colours`).
    static func usesColours(_ id: String) -> Bool {
        id == galleryId || (galleryFilter(id)?.usesColours ?? false)
    }

    /// The session colours a colour-reading gallery command records as explicit params (what
    /// photocraft's `filters_ext::prepare` fills in; done here too so the gallery commands record
    /// them whatever the shared runner does, and idempotent with it: given colours are kept).
    static func withColours(_ s: Session, _ id: String, _ p: JSONValue) -> JSONValue {
        guard usesColours(id), case .object(var m) = p else { return p }
        if m["foreground"] == nil { m["foreground"] = .rgba(s.tools.foreground) }
        if m["background"] == nil { m["background"] = .rgba(s.tools.background) }
        return .object(m)
    }

    // MARK: Catalogue

    /// The gallery catalogue for dialogs and agents: categories, filters and parameter notation
    /// (photocraft `catalogue`).
    static func catalogue() -> JSONValue {
        let filters: [JSONValue] = GalleryFilter.allCases.map { f in
            ["key": .string(f.key), "name": .string(f.name), "category": .string(f.category), "command": .string(f.commandID),
             "params": .string(f.paramsDoc)]
        }
        return ["categories": .strings(GalleryFilter.categories), "filters": .array(filters)]
    }

    // MARK: Commands

    /// One gallery filter or the stack: validated, colours recorded, then the shared runner.
    static func runOne(_ s: Session, _ id: String, _ p: JSONValue) throws -> JSONValue {
        try validateParams(id, p)
        let q = p.objectValue == nil ? JSONValue.object([:]) : p
        return try FilterCommands.runFilter(s, id, withColours(s, id, q))
    }

    static func runGallery(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        if p["list"]?.boolValue == true { return catalogue() }
        let effects = try effectsFromJSON(p).get()
        if effects.isEmpty {
            throw EngineError.other(
                #"filter.filterGallery needs `effects`: [{"filter": "<key>", "params": {...}}] (pass {"list": true} for the catalogue)"#)
        }
        // Normalize the recorded params (journal / smart filter) to the canonical form.
        let q = JSONValue.object(p.objectValue ?? [:]).removing("list")
        return try runOne(s, galleryId, q)
    }

    static func specs() -> [CommandSpec] {
        var v = [
            CommandSpec(galleryId, "Filter Gallery…", menu: ["Filter"], params: ##"{"effects":json,"foreground":json,"background":json,"list":bool}"##,
                        module: name, enabled: FilterCommands.hasFilterableLayer, run: runGallery),
        ]
        for f in GalleryFilter.allCases {
            let id = f.commandID
            v.append(CommandSpec(id, f.name, params: f.paramsDoc, module: name, enabled: FilterCommands.hasFilterableLayer) { s, p in
                try runOne(s, id, p)
            })
        }
        return v
    }
}
