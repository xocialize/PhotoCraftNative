// Port of photocraft-engine (crates/engine/src/swatch_cmds.rs and the swatch model of crates/engine/src/presets/swatches.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Window › Swatches: named colours in groups (folders), as in Photoshop's Swatches panel, and the
// `swatches.*` commands: add, delete, rename, reorder and group swatches, set the foreground or
// background colour from one, restore the defaults. A swatch keeps its colour in the model it was
// made in (RGB, HSB, CMYK, Lab, gray, or a colour-book entry kept verbatim); turning it into the
// RGB the foreground colour holds goes through colour management from the Edit › Color Settings
// working spaces (PCPlatform's ColorSync transforms replace photocraft-cms). Swatches are
// addressed by name (unique across the library), optionally narrowed by `group`, or by `index`
// (position across all groups, in panel order). The library is session state
// (`SwatchCommands.LibraryKey`, photocraft `PresetState::swatches`) and persists with the
// preferences (`libraryJSON` / `loadLibrary`). Import and export of `.aco` / `.ase` files use
// PCPSD's codecs (photocraft-psd `aco`/`ase`): `SwatchCommands+Files.swift`.

import Foundation
import PCDocument
import PCFoundation
import PCPlatform

enum SwatchCommands: CommandModule {
    static let name = "swatch_cmds"
    static let m = name

    /// Most swatches the library holds (imports beyond it are refused).
    static let maxSwatches = 100_000
    /// Most groups the library holds.
    static let maxGroups = 10_000
    /// Longest swatch or group name kept (characters).
    static let maxName = 255

    // MARK: Model (presets/swatches.rs)

    /// A swatch colour in its own model.
    enum SwatchColor: Hashable, Sendable {
        /// Red, green, blue 0…1 in the RGB working space.
        case rgb(SIMD3<Float>)
        /// Hue 0…360°, saturation and brightness 0…1 (an RGB working-space colour).
        case hsb(SIMD3<Float>)
        /// Cyan, magenta, yellow, black ink 0…1 in the CMYK working space.
        case cmyk(SIMD4<Float>)
        /// L* 0…100, a*, b* (D50).
        case lab(SIMD3<Float>)
        /// Black ink 0…1 (0 = white) in the gray working space, as Photoshop's K slider.
        case gray(Float)
        /// A colour space PhotoCraft does not model (colour books), kept verbatim from an `.aco`.
        case book(space: UInt16, values: [UInt16])

        /// Model id (`rgb`, `hsb`, `cmyk`, `lab`, `gray`, `book`).
        var model: String {
            switch self {
            case .rgb: "rgb"
            case .hsb: "hsb"
            case .cmyk: "cmyk"
            case .lab: "lab"
            case .gray: "gray"
            case .book: "book"
            }
        }

        /// Components in the units the Color Picker shows: RGB 0…255, HSB degrees and percent,
        /// CMYK and gray ink percent, Lab as is.
        var displayValues: [Double] {
            func r(_ v: Float, _ k: Double) -> Double { (Double(finite(v)) * k * 1000).rounded() / 1000 }
            switch self {
            case .rgb(let c): return [r(c.x, 255), r(c.y, 255), r(c.z, 255)]
            case .hsb(let c): return [r(c.x, 1), r(c.y, 100), r(c.z, 100)]
            case .cmyk(let c): return [r(c.x, 100), r(c.y, 100), r(c.z, 100), r(c.w, 100)]
            case .lab(let c): return [r(c.x, 1), r(c.y, 1), r(c.z, 1)]
            case .gray(let k): return [r(k, 100)]
            case .book(let space, let values): return [Double(space)] + values.map(Double.init)
            }
        }

        var json: JSONValue { ["model": .string(model), "values": .doubles(displayValues)] }

        /// Parse a command's colour: `"#rrggbb"` (RGB working space), or
        /// `{"model":"rgb|hsb|cmyk|lab|gray","values":[…]}` in `displayValues` units.
        static func fromParam(_ v: JSONValue) throws(ColorError) -> SwatchColor {
            if let s = v.stringValue {
                var h = Substring(s.trimmingCharacters(in: .whitespacesAndNewlines))
                while h.hasPrefix("#") { h = h.dropFirst() }
                guard h.count == 6, h.allSatisfy(\.isHexDigit), h.allSatisfy(\.isASCII) else {
                    throw ColorError(##"bad colour `\##(s)` ("#rrggbb" or {"model","values"})"##)
                }
                let b = Array(h.utf8)
                func byte(_ i: Int) -> Float { UInt8(String(decoding: b[i..<i + 2], as: UTF8.self), radix: 16).map { Float($0) / 255 } ?? 0 }
                return (.rgb(SIMD3(byte(0), byte(2), byte(4))))
            }
            guard let model = v["model"]?.stringValue else { throw ColorError("a colour needs `model` (rgb|hsb|cmyk|lab|gray) and `values`") }
            guard let arr = v["values"]?.arrayValue else { throw ColorError("a colour needs `values`") }
            var vals: [Float] = []
            for x in arr {
                guard let f = x.doubleValue, f.isFinite else { throw ColorError("colour values must be finite numbers") }
                vals.append(Float(f))
            }
            func need(_ n: Int) -> String? { vals.count == n ? nil : "a \(model) colour has \(n) values, got \(vals.count)" }
            func pct(_ v: Float) -> Float { min(max(v / 100, 0), 1) }
            switch model {
            case "rgb":
                if let e = need(3) { throw ColorError(e) }
                return (.rgb(SIMD3(min(max(vals[0] / 255, 0), 1), min(max(vals[1] / 255, 0), 1), min(max(vals[2] / 255, 0), 1))))
            case "hsb":
                if let e = need(3) { throw ColorError(e) }
                return (.hsb(SIMD3(remEuclid(vals[0], 360), pct(vals[1]), pct(vals[2]))))
            case "cmyk":
                if let e = need(4) { throw ColorError(e) }
                return (.cmyk(SIMD4(pct(vals[0]), pct(vals[1]), pct(vals[2]), pct(vals[3]))))
            case "lab":
                if let e = need(3) { throw ColorError(e) }
                return (.lab(SIMD3(min(max(vals[0], 0), 100), min(max(vals[1], -128), 127), min(max(vals[2], -128), 127))))
            case "gray":
                if let e = need(1) { throw ColorError(e) }
                return (.gray(pct(vals[0])))
            default:
                throw ColorError("unknown colour model `\(model)` (rgb|hsb|cmyk|lab|gray)")
            }
        }

        /// photocraft's serde form (`{"model":…,"values":…}`; gray's values are one number, a
        /// book's `{"space","values"}`).
        var serde: JSONValue {
            switch self {
            case .rgb(let c), .hsb(let c), .lab(let c): ["model": .string(model), "values": .floats([c.x, c.y, c.z])]
            case .cmyk(let c): ["model": "cmyk", "values": .floats([c.x, c.y, c.z, c.w])]
            case .gray(let k): ["model": "gray", "values": .float(k)]
            case .book(let space, let values): ["model": "book", "values": ["space": .int(Int(space)), "values": .array(values.map { .int(Int($0)) })]]
            }
        }

        static func fromSerde(_ v: JSONValue) -> SwatchColor? {
            guard let model = v["model"]?.stringValue, let vals = v["values"] else { return nil }
            func floats(_ n: Int) -> [Float]? {
                guard let a = vals.arrayValue, a.count == n else { return nil }
                let f = a.compactMap(\.floatValue)
                return f.count == n ? f : nil
            }
            switch model {
            case "rgb": return floats(3).map { .rgb(SIMD3($0[0], $0[1], $0[2])) }
            case "hsb": return floats(3).map { .hsb(SIMD3($0[0], $0[1], $0[2])) }
            case "lab": return floats(3).map { .lab(SIMD3($0[0], $0[1], $0[2])) }
            case "cmyk": return floats(4).map { .cmyk(SIMD4($0[0], $0[1], $0[2], $0[3])) }
            case "gray": return vals.floatValue.map { .gray($0) }
            case "book":
                guard let space = vals["space"]?.uint64Value.flatMap({ UInt16(exactly: $0) }), let a = vals["values"]?.arrayValue, a.count == 4 else { return nil }
                let v = a.compactMap { $0.uint64Value.flatMap { UInt16(exactly: $0) } }
                return v.count == 4 ? .book(space: space, values: v) : nil
            default: return nil
            }
        }
    }

    /// Why a colour param doesn't parse.
    struct ColorError: Error {
        var message: String
        init(_ m: String) { message = m }
    }

    /// The colour type Adobe Swatch Exchange files carry (kept for round trips).
    enum SwatchKind: String, Hashable, Sendable {
        case process, global, spot

        static func parse(_ s: String) -> SwatchKind? {
            switch s {
            case "process", "normal": .process
            case "global": .global
            case "spot": .spot
            default: nil
            }
        }
    }

    struct Swatch: Hashable, Sendable {
        var name: String
        var color: SwatchColor
        var kind: SwatchKind = .process

        var serde: JSONValue {
            var o: [String: JSONValue] = ["name": .string(name), "color": color.serde]
            if kind != .process { o["kind"] = .string(kind.rawValue) }
            return .object(o)
        }
    }

    /// A named folder of swatches (photocraft `presets::Group<Swatch>`).
    struct Group: Hashable, Sendable {
        var name: String
        var items: [Swatch]
    }

    /// The Swatches panel library (photocraft `s.presets.swatches`); `revision` moves on every
    /// change (photocraft `presets.rev`).
    struct Library: Hashable, Sendable {
        var groups: [Group]
        var revision: UInt64 = 0
    }

    /// Session state: the swatch library, the built-in defaults until changed.
    enum LibraryKey: StateKey {
        static let defaultValue = Library(groups: SwatchCommands.builtin())
    }

    static func finite(_ v: Float) -> Float { v.isFinite ? v : 0 }
    static func unit(_ v: Float) -> Float { min(max(finite(v), 0), 1) }
    static func remEuclid(_ a: Float, _ b: Float) -> Float {
        let r = a.truncatingRemainder(dividingBy: b)
        return r < 0 ? r + abs(b) : r
    }

    /// HSB (hue in degrees) to RGB, both in the same RGB space.
    static func hsbToRGB(_ c: SIMD3<Float>) -> SIMD3<Float> {
        let s = unit(c.y), v = unit(c.z)
        let h = remEuclid(finite(c.x), 360) / 60
        let ch = v * s
        let x = ch * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
        let (r, g, b): (Float, Float, Float)
        switch h.isFinite ? Int(h) : 0 {
        case 0: (r, g, b) = (ch, x, 0)
        case 1: (r, g, b) = (x, ch, 0)
        case 2: (r, g, b) = (0, ch, x)
        case 3: (r, g, b) = (0, x, ch)
        case 4: (r, g, b) = (x, 0, ch)
        default: (r, g, b) = (ch, 0, x)
        }
        let m = v - ch
        return SIMD3(unit(r + m), unit(g + m), unit(b + m))
    }

    /// `#rrggbb` of RGB components.
    static func hex(_ c: SIMD3<Float>) -> String {
        func q(_ v: Float) -> Int { Int((unit(v) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", q(c.x), q(c.y), q(c.z))
    }

    /// Converts swatch colours to the RGB working space (relative colorimetric + black point
    /// compensation, Photoshop's default), from the Color Settings working spaces (photocraft
    /// `SwatchConv`). Build one per call; evaluating is cheap.
    struct Conv {
        var cmyk: ColorTransform?
        var lab: ColorTransform?
        var gray: ColorTransform?

        init(_ s: Session?) {
            let rgb = Conv.working(s, .rgb)
            func link(_ src: ICCProfile) -> ColorTransform? { try? ColorTransform.cached(source: src, destination: rgb, options: .photoshopDefault) }
            cmyk = link(Conv.working(s, .cmyk))
            lab = link(BuiltinProfile.labD50.profile)
            gray = link(Conv.working(s, .grayscale))
        }

        /// The session's working profile for `mode` (Color Settings), else the built-in default.
        static func working(_ s: Session?, _ mode: ColorMode) -> ICCProfile {
            let key: String = switch mode {
            case .cmyk: "colorSettings.workingCmyk"
            case .grayscale: "colorSettings.workingGray"
            default: "colorSettings.workingRgb"
            }
            let want: ProfileColorSpace = switch mode {
            case .cmyk: .cmyk
            case .grayscale: .gray
            default: .rgb
            }
            if let spec = s?.preferences[key]?.stringValue, let p = resolveProfile(spec), p.colorSpace == want { return p }
            return BuiltinProfile.defaultProfile(for: mode)
        }

        /// A built-in profile id or an `.icc` path.
        static func resolveProfile(_ spec: String) -> ICCProfile? {
            if let b = BuiltinProfile.from(id: spec) { return b.profile }
            guard spec.lowercased().hasSuffix(".icc") || spec.lowercased().hasSuffix(".icm") else { return nil }
            return try? ICCProfile(contentsOf: URL(fileURLWithPath: spec))
        }

        /// The colour in the RGB working space (what the foreground colour holds), 0…1.
        /// Colour-book entries, which have no colour of their own here, are mid gray.
        func rgb(_ c: SwatchColor) -> SIMD3<Float> {
            func eval(_ t: ColorTransform?, _ input: [Float]) -> SIMD3<Float>? {
                guard let t else { return nil }
                let o = t.eval(input)
                guard o.count >= 3 else { return nil }
                return SIMD3(unit(o[0]), unit(o[1]), unit(o[2]))
            }
            switch c {
            case .rgb(let v): return SIMD3(unit(v.x), unit(v.y), unit(v.z))
            case .hsb(let v): return hsbToRGB(v)
            case .cmyk(let v0):
                let v = SIMD4(unit(v0.x), unit(v0.y), unit(v0.z), unit(v0.w))
                return eval(cmyk, [v.x, v.y, v.z, v.w]) ?? ColorConvert.cmykToRGB(v)
            case .lab(let l):
                let lab = SIMD3<Double>(Double(finite(l.x)), Double(finite(l.y)), Double(finite(l.z)))
                // The profile's device values (ColorSync's float Lab encoding), in range.
                let e = LabEncoding.colorSync.encode(SIMD3(min(max(lab.x, 0), 100), min(max(lab.y, -128), 127), min(max(lab.z, -128), 127)))
                return eval(self.lab, [e.x, e.y, e.z]) ?? ColorConvert.labToSRGB(SIMD3(Float(lab.x), Float(lab.y), Float(lab.z)))
            case .gray(let k):
                let level = 1 - unit(k)
                return eval(gray, [level]) ?? SIMD3(repeating: level)
            case .book: return SIMD3(repeating: 0.5)
            }
        }
    }

    /// The default library: 40 colours in four groups (photocraft's own palette).
    static func builtin() -> [Group] {
        func rgb(_ n: String, _ c: (Int, Int, Int)) -> Swatch {
            Swatch(name: n, color: .rgb(SIMD3(Float(c.0) / 255, Float(c.1) / 255, Float(c.2) / 255)))
        }
        let grays: [(String, Int)] = [
            ("Black", 0), ("90% Gray", 26), ("80% Gray", 51), ("70% Gray", 77), ("60% Gray", 102), ("50% Gray", 128), ("40% Gray", 153),
            ("30% Gray", 179), ("20% Gray", 204), ("White", 255),
        ]
        let hues = ["Red", "Orange", "Yellow", "Yellow Green", "Green", "Cyan Green", "Cyan", "Blue", "Violet", "Magenta"]
        let pastel = [(236, 128, 128), (244, 176, 132), (250, 224, 128), (214, 240, 128), (150, 232, 150), (128, 232, 200), (128, 220, 240),
                      (128, 176, 244), (168, 144, 244), (232, 144, 232)]
        let pure = [(230, 40, 40), (245, 120, 30), (250, 210, 30), (160, 220, 40), (40, 200, 80), (30, 200, 170), (30, 170, 230), (40, 100, 230),
                    (120, 70, 220), (210, 50, 180)]
        let dark = [(120, 20, 20), (130, 60, 10), (130, 110, 10), (80, 120, 20), (20, 100, 40), (10, 100, 90), (10, 80, 120), (20, 50, 120),
                    (60, 30, 110), (110, 20, 90)]
        func row(_ prefix: String, _ cs: [(Int, Int, Int)]) -> [Swatch] {
            zip(hues, cs).map { h, c in rgb(prefix.isEmpty ? h : "\(prefix) \(h)", c) }
        }
        return [
            Group(name: "Grays", items: grays.map { rgb($0.0, ($0.1, $0.1, $0.1)) }),
            Group(name: "Pastel", items: row("Pastel", pastel)),
            Group(name: "Pure", items: row("", pure)),
            Group(name: "Dark", items: row("Dark", dark)),
        ]
    }

    // MARK: Persistence

    /// Trim a hand-edited or imported library to the limits (never refuse to start over it).
    static func capLibrary(_ groups: inout [Group]) {
        if groups.count > maxGroups { groups.removeSubrange(maxGroups...) }
        var left = maxSwatches
        for gi in groups.indices {
            if groups[gi].items.count > left { groups[gi].items.removeSubrange(left...) }
            left -= groups[gi].items.count
            groups[gi].name = clip(groups[gi].name)
            for ii in groups[gi].items.indices { groups[gi].items[ii].name = clip(groups[gi].items[ii].name) }
        }
    }

    /// The library as the preferences document stores it (photocraft `presets.swatches`).
    static func libraryJSON(_ s: Session) -> JSONValue {
        .array(s.state[LibraryKey.self].groups.map { g in ["name": .string(g.name), "items": .array(g.items.map(\.serde))] })
    }

    /// Restores the library from the preferences document; a missing or unreadable entry keeps
    /// the current library (photocraft `load_presets_json`), and a hand-edited one is capped.
    static func loadLibrary(_ s: Session, _ v: JSONValue?) {
        guard let arr = v?.arrayValue else { return }
        var groups: [Group] = []
        for g in arr {
            guard let name = g["name"]?.stringValue, let items = g["items"]?.arrayValue else { return }
            var out: [Swatch] = []
            for it in items {
                guard let n = it["name"]?.stringValue, let c = it["color"].flatMap(SwatchColor.fromSerde) else { return }
                let kind = it["kind"]?.stringValue.flatMap { SwatchKind(rawValue: $0) } ?? .process
                out.append(Swatch(name: n, color: c, kind: kind))
            }
            groups.append(Group(name: name, items: out))
        }
        capLibrary(&groups)
        s.state[LibraryKey.self].groups = groups
        s.state[LibraryKey.self].revision &+= 1
    }

    // MARK: Helpers (presets/mod.rs)

    static func clip(_ s: String) -> String { String(s.prefix(maxName)) }

    static func total(_ groups: [Group]) -> Int { groups.reduce(0) { $0 + $1.items.count } }

    /// photocraft `presets::str_param`: a trimmed, non-empty string.
    static func strParam(_ p: JSONValue, _ k: String) -> String? {
        guard let s = p[k]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }

    static func nameParam(_ p: JSONValue, _ k: String, _ cmd: String) throws -> String? {
        guard let v = p[k], v != .null else { return nil }
        if let s = v.stringValue, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return clip(s.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        throw EngineError.bad(cmd, "`\(k)` must be a non-empty string")
    }

    /// photocraft `presets::find`: (group index, item index) of the first swatch named `name`.
    static func find(_ groups: [Group], _ name: String, group: String?) -> (Int, Int)? {
        for (gi, g) in groups.enumerated() where group == nil || g.name == group {
            if let ii = g.items.firstIndex(where: { $0.name == name }) { return (gi, ii) }
        }
        return nil
    }

    /// `base`, or `base 2`, `base 3`… so names stay unique across all groups.
    static func uniqueName(_ groups: [Group], _ base: String) -> String {
        let taken = Set(groups.flatMap { $0.items.map(\.name) })
        if !taken.contains(base) { return base }
        var i = 2
        while taken.contains("\(base) \(i)") { i += 1 }
        return "\(base) \(i)"
    }

    /// `base`, or `base 1`, `base 2`… (photocraft `gradients::unique_group`).
    static func uniqueGroup(_ groups: [Group], _ base: String) -> String {
        let taken = Set(groups.map(\.name))
        if !taken.contains(base) { return base }
        var i = 1
        while taken.contains("\(base) \(i)") { i += 1 }
        return "\(base) \(i)"
    }

    /// Name → position of the first swatch with that name (optionally only in `group`).
    static func indexByName(_ groups: [Group], group: String?) -> [String: (Int, Int)] {
        var m: [String: (Int, Int)] = [:]
        for (gi, g) in groups.enumerated() where group == nil || g.name == group {
            for (ii, sw) in g.items.enumerated() where m[sw.name] == nil { m[sw.name] = (gi, ii) }
        }
        return m
    }

    static func library(_ s: Session) -> [Group] { s.state[LibraryKey.self].groups }

    /// Stores the library and records the change (photocraft `presets_changed`: the panel
    /// revision moves and the preferences document is dirty).
    static func store(_ s: Session, _ groups: [Group]) {
        s.state[LibraryKey.self].groups = groups
        s.state[LibraryKey.self].revision &+= 1
        s.emit(.preferencesChanged)
    }

    /// The swatch a command names: `"swatch"` (name, narrowed by `"group"`) or `"index"`.
    static func locate(_ s: Session, _ p: JSONValue, _ cmd: String) throws -> (Int, Int) {
        let groups = library(s)
        if let name = strParam(p, "swatch") {
            guard let at = find(groups, name, group: strParam(p, "group")) else { throw EngineError.bad(cmd, "no swatch \"\(name)\" (see swatches.list)") }
            return at
        }
        if let v = p["index"] {
            guard let i = v.uint64Value else { throw EngineError.bad(cmd, "`index` must be a non-negative integer") }
            var left = i
            for (gi, g) in groups.enumerated() {
                if left < UInt64(g.items.count) { return (gi, Int(left)) }
                left -= UInt64(g.items.count)
            }
            throw EngineError.bad(cmd, "no swatch at index \(i) (the panel has \(total(groups)))")
        }
        throw EngineError.bad(cmd, "give `swatch` (a name) or `index`")
    }

    static func groupOf(_ s: Session, _ name: String, _ cmd: String) throws -> Int {
        guard let i = library(s).firstIndex(where: { $0.name == name }) else { throw EngineError.bad(cmd, "no swatch group \"\(name)\"") }
        return i
    }

    static func swatchJSON(_ conv: Conv, _ sw: Swatch) -> JSONValue {
        var v = sw.color.json.members
        v["name"] = .string(sw.name)
        v["hex"] = .string(hex(conv.rgb(sw.color)))
        if sw.kind != .process { v["kind"] = .string(sw.kind.rawValue) }
        return .object(v)
    }

    // MARK: Commands

    static let hasSwatches: CommandEnabled = { s, _ in total(library(s)) > 0 ? nil : "the Swatches panel is empty" }
    static let hasGroups: CommandEnabled = { s, _ in library(s).isEmpty ? "there are no swatch groups" : nil }

    static func list(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let conv = Conv(s)
        let groups = library(s)
        return ["groups": .array(groups.map { g in ["name": .string(g.name), "swatches": .array(g.items.map { swatchJSON(conv, $0) })] }),
                "count": .int(total(groups))]
    }

    static func add(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "swatches.add"
        let color: SwatchColor
        if let v = p["color"], v != .null {
            do { color = try SwatchColor.fromParam(v) } catch { throw EngineError.bad(cmd, error.message) }
        } else {
            let f = s.tools.foreground
            func c(_ v: Float) -> Float { v.isFinite ? min(max(v, 0), 1) : 0 }
            color = .rgb(SIMD3(c(f.x), c(f.y), c(f.z)))
        }
        let kind: SwatchKind
        if let k = strParam(p, "kind") {
            guard let x = SwatchKind.parse(k) else { throw EngineError.bad(cmd, "unknown kind `\(k)` (process|global|spot)") }
            kind = x
        } else {
            kind = .process
        }
        var groups = library(s)
        if total(groups) >= maxSwatches { throw EngineError.bad(cmd, "the Swatches panel is full (\(maxSwatches) swatches)") }
        let group = try nameParam(p, "group", cmd)
        let explicit = try nameParam(p, "name", cmd)
        let name: String
        if let n = explicit {
            name = uniqueName(groups, n)
        } else {
            // Photoshop's default: "Color Swatch 1", "Color Swatch 2"…
            let taken = Set(groups.flatMap { $0.items.map(\.name) })
            var i = 1
            while taken.contains("Color Swatch \(i)") { i += 1 }
            name = "Color Swatch \(i)"
        }
        let gi: Int
        if let g = group {
            if let i = groups.firstIndex(where: { $0.name == g }) {
                gi = i
            } else {
                if groups.count >= maxGroups { throw EngineError.bad(cmd, "too many swatch groups") }
                groups.append(Group(name: g, items: []))
                gi = groups.count - 1
            }
        } else {
            if groups.isEmpty { groups.append(Group(name: "Swatches", items: [])) }
            gi = 0
        }
        let at: Int
        if let v = p["index"], v != .null {
            guard let i = v.uint64Value else { throw EngineError.bad(cmd, "`index` must be a non-negative integer") }
            at = Int(min(i, UInt64(groups[gi].items.count)))
        } else {
            at = groups[gi].items.count
        }
        groups[gi].items.insert(Swatch(name: name, color: color, kind: kind), at: at)
        let gname = groups[gi].name
        store(s, groups)
        return ["name": .string(name), "group": .string(gname), "index": .int(at)]
    }

    static func delete(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "swatches.delete"
        var groups = library(s)
        var targets: [(Int, Int)]
        if let a = p["swatch"]?.arrayValue {
            let ix = indexByName(groups, group: strParam(p, "group"))
            targets = []
            targets.reserveCapacity(min(a.count, maxSwatches))
            for n in a {
                guard let name = n.stringValue else { throw EngineError.bad(cmd, "`swatch` names must be strings") }
                guard let at = ix[name] else { throw EngineError.bad(cmd, "no swatch \"\(name)\" (see swatches.list)") }
                targets.append(at)
            }
        } else {
            targets = [try locate(s, p, cmd)]
        }
        // Remove from the back so earlier positions stay valid; duplicates count once.
        targets.sort { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
        var unique: [(Int, Int)] = []
        for t in targets where unique.last.map({ $0 != t }) ?? true { unique.append(t) }
        var names: [String] = []
        for (gi, ii) in unique.reversed() where gi < groups.count && ii < groups[gi].items.count {
            names.append(groups[gi].items.remove(at: ii).name)
        }
        names.reverse()
        store(s, groups)
        return ["deleted": .strings(names)]
    }

    static func rename(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "swatches.rename"
        let (gi, ii) = try locate(s, p, cmd)
        guard let to = try nameParam(p, "name", cmd) else { throw EngineError.bad(cmd, "missing `name`") }
        var groups = library(s)
        if groups[gi].items[ii].name != to && find(groups, to, group: nil) != nil {
            throw EngineError.bad(cmd, "a swatch named \"\(to)\" already exists")
        }
        groups[gi].items[ii].name = to
        store(s, groups)
        return ["name": .string(to)]
    }

    static func move(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "swatches.move"
        let (gi, ii) = try locate(s, p, cmd)
        let ti = try nameParam(p, "to", cmd).map { try groupOf(s, $0, cmd) } ?? gi
        var at: UInt64?
        if let v = p["position"], v != .null {
            guard let x = v.uint64Value else { throw EngineError.bad(cmd, "`position` must be a non-negative integer") }
            at = x
        }
        var groups = library(s)
        let item = groups[gi].items.remove(at: ii)
        let n = groups[ti].items.count
        let pos = Int(min(at ?? UInt64(n), UInt64(n)))
        groups[ti].items.insert(item, at: pos)
        let gname = groups[ti].name
        store(s, groups)
        return ["group": .string(gname), "position": .int(pos)]
    }

    static func newGroup(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "swatches.newGroup"
        var groups = library(s)
        if groups.count >= maxGroups { throw EngineError.bad(cmd, "too many swatch groups") }
        let base = try nameParam(p, "name", cmd) ?? "Group"
        // Swatches to move into the new group (Photoshop: New Group from the selected swatches).
        var moving: [(Int, Int)] = []
        if let a = p["swatches"] {
            guard let a = a.arrayValue else { throw EngineError.bad(cmd, "`swatches` must be a list of names") }
            let ix = indexByName(groups, group: nil)
            for n in a {
                guard let name = n.stringValue else { throw EngineError.bad(cmd, "`swatches` names must be strings") }
                guard let at = ix[name] else { throw EngineError.bad(cmd, "no swatch \"\(name)\"") }
                moving.append(at)
            }
        }
        moving.sort { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
        var unique: [(Int, Int)] = []
        for t in moving where unique.last.map({ $0 != t }) ?? true { unique.append(t) }
        let name = uniqueGroup(groups, base)
        var items: [Swatch] = []
        for (gi, ii) in unique.reversed() { items.append(groups[gi].items.remove(at: ii)) }
        items.reverse()
        let n = items.count
        groups.append(Group(name: name, items: items))
        store(s, groups)
        return ["group": .string(name), "moved": .int(n)]
    }

    static func renameGroup(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "swatches.renameGroup"
        guard let g = try nameParam(p, "group", cmd) else { throw EngineError.bad(cmd, "missing `group`") }
        guard let to = try nameParam(p, "name", cmd) else { throw EngineError.bad(cmd, "missing `name`") }
        let i = try groupOf(s, g, cmd)
        var groups = library(s)
        if g != to && groups.contains(where: { $0.name == to }) { throw EngineError.bad(cmd, "a group named \"\(to)\" already exists") }
        groups[i].name = to
        store(s, groups)
        return ["group": .string(to)]
    }

    static func deleteGroup(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "swatches.deleteGroup"
        guard let g = try nameParam(p, "group", cmd) else { throw EngineError.bad(cmd, "missing `group`") }
        var keep = false
        if let v = p["keepSwatches"], v != .null {
            guard let b = v.boolValue else { throw EngineError.bad(cmd, "`keepSwatches` must be true or false") }
            keep = b
        }
        let i = try groupOf(s, g, cmd)
        var groups = library(s)
        if keep && groups.count < 2 { throw EngineError.bad(cmd, "there is no other group to keep the swatches in") }
        let removed = groups.remove(at: i)
        let n = removed.items.count
        if keep {
            // Into the group above (or the new first group), like Photoshop's "Delete Group Only".
            let into = min(max(i - 1, 0), max(groups.count - 1, 0))
            if into < groups.count { groups[into].items += removed.items }
        }
        store(s, groups)
        return ["group": .string(g), (keep ? "kept" : "deleted"): .int(n)]
    }

    static func use(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "swatches.use"
        let (gi, ii) = try locate(s, p, cmd)
        let target = strParam(p, "target") ?? "foreground"
        let sw = library(s)[gi].items[ii]
        let rgb = Conv(s).rgb(sw.color)
        let c = SIMD4<Float>(rgb, 1)
        switch target {
        case "foreground": s.tools.foreground = c
        case "background": s.tools.background = c
        default: throw EngineError.bad(cmd, "unknown target `\(target)` (foreground|background)")
        }
        s.emit(.toolsChanged)
        return ["swatch": .string(sw.name), "target": .string(target), "hex": .string(hex(rgb))]
    }

    static func reset(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "swatches.reset"
        var append = false
        if let v = p["append"], v != .null {
            guard let b = v.boolValue else { throw EngineError.bad(cmd, "`append` must be true or false") }
            append = b
        }
        let b = builtin()
        var groups = library(s)
        if append {
            if total(groups) + total(b) > maxSwatches || groups.count + b.count > maxGroups { throw EngineError.bad(cmd, "the Swatches panel is full") }
            for var g in b {
                g.name = uniqueGroup(groups, g.name)
                for k in g.items.indices { g.items[k].name = uniqueName(groups, g.items[k].name) }
                groups.append(g)
            }
        } else {
            groups = b
        }
        store(s, groups)
        return ["groups": .int(groups.count), "count": .int(total(groups))]
    }

    static func register(into r: inout CommandRegistry) {
        let color = ##""#rrggbb"|{"model":"rgb|hsb|cmyk|lab|gray","values":[rgb 0..255 | hue°,s%,b% | c%,m%,y%,k% | L,a,b | k%]}"##
        let target = ##""swatch":name (or "index":n across all groups),"group":name? (narrows the name lookup)"##
        r.add([
            CommandSpec("swatches.list", "Swatches",
                        params: ##"{} → {groups:[{name,swatches:[{name,model,values,hex,kind?}]}],count}. values are in Color Picker units; hex is the colour in the RGB working space."##,
                        module: m, journal: false, run: list),
            CommandSpec("swatches.add", "New Swatch…",
                        params: ##"{"color":"## + color + ##"?=foreground,"name":str?="Color Swatch N","group":name?=first (created when missing),"index":n?=end,"kind":"process|global|spot"="process"} → {name,group,index}"##,
                        module: m, run: add),
            CommandSpec("swatches.delete", "Delete Swatch", params: "{" + target + ##"; "swatch" may be a list of names} → {deleted:[names]}"##,
                        module: m, enabled: hasSwatches, run: delete),
            CommandSpec("swatches.rename", "Rename Swatch…", params: "{" + target + ##","name":str} → {name}"##,
                        module: m, enabled: hasSwatches, run: rename),
            CommandSpec("swatches.move", "Move Swatch", params: "{" + target + ##","to":group?=its own group,"position":n?=end} → {group,position}"##,
                        module: m, enabled: hasSwatches, run: move),
            CommandSpec("swatches.newGroup", "New Swatch Group…",
                        params: ##"{"name":str="Group" (made unique),"swatches":[names]? (moved into the new group)} → {group,moved}"##, module: m, run: newGroup),
            CommandSpec("swatches.renameGroup", "Rename Swatch Group…", params: ##"{"group":name,"name":str} → {group}"##,
                        module: m, enabled: hasGroups, run: renameGroup),
            CommandSpec("swatches.deleteGroup", "Delete Swatch Group",
                        params: ##"{"group":name,"keepSwatches":bool=false (move its swatches into the group above)} → {group,deleted|kept}"##,
                        module: m, enabled: hasGroups, run: deleteGroup),
            CommandSpec("swatches.use", "Use Swatch",
                        params: "{" + target + ##","target":"foreground|background"="foreground"} → {swatch,target,hex}. CMYK, Lab and gray swatches are converted to the RGB working space with colour management."##,
                        module: m, enabled: hasSwatches, run: use),
            CommandSpec("swatches.reset", "Reset Swatches",
                        params: ##"{"append":bool=false (add the defaults instead of replacing the library)} → {groups,count}"##, module: m, run: reset),
            CommandSpec("swatches.import", "Import Swatches…",
                        params: ##"{"path":".aco or .ase file"?,"data":base64 bytes?,"format":"aco|ase"? (detected),"mode":"append|replace"="append","group":str?=file name (the group for ungrouped colours)} → {format,mode,groups,count,warnings}"##,
                        module: m, run: importFile),
            CommandSpec("swatches.export", "Export Swatches…",
                        params: ##"{"format":"aco|ase"?=from path, else aco,"path":file? (else the bytes come back as base64 `data`),"group":name? (only that group),"swatches":[names]? (only these)} → {format,count,bytes,warnings,path|data}"##,
                        module: m, enabled: hasSwatches, run: exportFile),
        ])
    }
}
