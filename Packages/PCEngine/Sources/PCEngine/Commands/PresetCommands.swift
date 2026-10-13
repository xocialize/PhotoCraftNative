// Port of photocraft-engine (crates/engine/src/presets/mod.rs, presets/gradients.rs, presets/patterns.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Preset panels: Window › Gradients, Patterns, Styles, Shapes and Tool Presets. Photoshop keeps
// presets in named groups (folders) the panels show as thumbnail grids or lists; the engine owns
// that data (session state, `Key`) so every frontend sees and edits the same sets through
// `<kind>.presets.*`. This file: the shared group machinery, persistence, gradients (the Gradient
// tool's current gradient, Gradient Fill layers from presets) and pattern folders over the pattern
// library. Styles, shapes and tool presets are in `PresetCommands+Library.swift`. Clone sources and
// swatches (also photocraft `presets`) are other modules'. The built-in groups are photocraft's
// own (clean-room) designs.

import Foundation
import PCDocument
import PCFoundation

enum PresetCommands: CommandModule {
    static let name = "presets"
    static let m = name

    static func register(into r: inout CommandRegistry) {
        r.add(gradientSpecs())
        r.add(patternSpecs())
        r.add(styleSpecs())
        r.add(shapeSpecs())
        r.add(toolSpecs())
    }

    // MARK: State

    /// A named folder of presets.
    struct Group<T: Sendable>: Sendable {
        var name: String
        var items: [T]
        init(_ name: String, _ items: [T]) { self.name = name; self.items = items }
    }

    /// Anything with a display name (presets, pattern references).
    protocol Named {
        var presetName: String { get set }
    }

    /// A pattern folder entry: a library pattern's id (JSON: the id string).
    struct PatternRef: Named, Hashable, Sendable, Codable {
        var id: String
        var presetName: String {
            get { id }
            set { id = newValue }
        }
        init(_ id: String) { self.id = id }
        init(from decoder: any Decoder) throws { id = try decoder.singleValueContainer().decode(String.self) }
        func encode(to encoder: any Encoder) throws {
            var c = encoder.singleValueContainer()
            try c.encode(id)
        }
    }

    /// Edit › Define Custom Shape results (photocraft `EditState::custom_shapes`), shown in the
    /// Shapes panel's trailing "Custom Shapes" group. The Edit-menu port should keep its custom
    /// shapes here (or point `customShapes` at its own state).
    struct CustomShape: Hashable, Sendable, Codable {
        var name: String
        var path: VectorPath
    }

    enum CustomShapesKey: StateKey {
        static let defaultValue: [CustomShape] = []
    }

    /// All preset sets plus the panel state the engine needs (photocraft `PresetState`, minus the
    /// clone sources, swatches and document presets other modules own).
    struct State: Sendable {
        var gradients: [Group<GradientPreset>]
        /// The Gradient tool's current gradient (Gradients panel selection / gradient picker).
        var gradient: GradientPreset
        var styles: [Group<StylePreset>]
        var shapes: [Group<ShapePreset>]
        /// Pattern groups: pattern ids per folder (the patterns themselves live in the library).
        var patternGroups: [Group<PatternRef>]
        /// The pattern the Patterns panel selected (Fill, Pattern fill layers default to it).
        var pattern: String?
        var toolPresets: [ToolPreset]
        /// The user defaults "Make Default" in the Layer Style dialog saves (effect kind → param
        /// set); "Reset to Default" restores them.
        var layerDefaults: [String: JSONValue]
        /// Bumped on every preset change (UIs key thumbnail caches on it).
        var rev: UInt64

        init() {
            gradients = PresetCommands.builtinGradients()
            gradient = .foregroundToBackground
            styles = PresetCommands.builtinStyles()
            shapes = PresetCommands.builtinShapes()
            patternGroups = PresetCommands.builtinPatternGroups()
            pattern = nil
            toolPresets = PresetCommands.builtinTools()
            layerDefaults = [:]
            rev = 0
        }
    }

    enum Key: StateKey {
        static let defaultValue = State()
    }

    static func state(_ s: Session) -> State { s.state[Key.self] }

    /// photocraft `presets_changed`: bumps the panel revision and marks the preferences dirty so
    /// the shell persists them (`persistedJSON`).
    static func presetsChanged(_ s: Session) {
        s.state[Key.self].rev += 1
        s.emit(.preferencesChanged)
    }

    // MARK: Persistence

    /// The JSON photocraft saves with the preferences under `"presets"` (this module's sets).
    static func persistedJSON(_ s: Session) -> JSONValue {
        let st = state(s)
        return [
            "gradients": .encoded(st.gradients.map(CodableGroup.init)),
            "gradient": .encoded(st.gradient),
            "styles": .encoded(st.styles.map(CodableGroup.init)),
            "shapes": .encoded(st.shapes.map(CodableGroup.init)),
            "pattern_groups": .encoded(st.patternGroups.map(CodableGroup.init)),
            "tool_presets": .encoded(st.toolPresets),
            "custom_shapes": .encoded(s.state[CustomShapesKey.self]),
            "layer_defaults": .object(st.layerDefaults),
        ]
    }

    /// photocraft `Session::load_presets_json`: restores presets saved by `persistedJSON`. Missing
    /// sets keep their defaults; a malformed blob is ignored (presets are never worth refusing to
    /// start over). Tool presets load entry by entry.
    static func loadPersisted(_ s: Session, _ v: JSONValue) {
        guard v.objectValue != nil else { return }
        func field<T: Decodable>(_ k: String, _ t: T.Type) throws -> T? {
            guard let x = v[k], x != .null else { return nil }
            return try x.decode(as: T.self)
        }
        let gradients: [CodableGroup<GradientPreset>]?, gradient: GradientPreset?, styles: [CodableGroup<StylePreset>]?
        let shapes: [CodableGroup<ShapePreset>]?, patternGroups: [CodableGroup<PatternRef>]?, custom: [CustomShape]?
        let defaults: [String: JSONValue]?
        do {
            gradients = try field("gradients", [CodableGroup<GradientPreset>].self)
            gradient = try field("gradient", GradientPreset.self)
            styles = try field("styles", [CodableGroup<StylePreset>].self)
            shapes = try field("shapes", [CodableGroup<ShapePreset>].self)
            patternGroups = try field("pattern_groups", [CodableGroup<PatternRef>].self)
            custom = try field("custom_shapes", [CustomShape].self)
            defaults = try field("layer_defaults", [String: JSONValue].self)
        } catch {
            return
        }
        var st = state(s)
        if let g = gradients { st.gradients = g.map(\.group) }
        if let g = gradient { st.gradient = g }
        if let g = styles { st.styles = g.map(\.group) }
        if let g = shapes { st.shapes = g.map(\.group) }
        if let g = patternGroups { st.patternGroups = g.map(\.group) }
        if let t = v["tool_presets"], t != .null { st.toolPresets = loadToolPresets(t) }
        if let d = defaults { st.layerDefaults = d }
        st.rev += 1
        s.state[Key.self] = st
        if let c = custom { s.state[CustomShapesKey.self] = c }
    }

    /// serde's form of a `Group`: `{"name", "items"}`.
    struct CodableGroup<T: Codable & Sendable>: Codable {
        var name: String
        var items: [T]
        init(_ g: Group<T>) { name = g.name; items = g.items }
        var group: Group<T> { Group(name, items) }
    }

    // MARK: Shared helpers

    static func strParam(_ p: JSONValue, _ k: String) -> String? {
        guard let s = p[k]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }

    static func reqStr(_ p: JSONValue, _ k: String, _ cmd: String) throws -> String {
        guard let s = strParam(p, k) else { throw EngineError.bad(cmd, "missing `\(k)`") }
        return s
    }

    /// Locates a preset by name (optionally within `group`): (group index, item index).
    static func find<T: Named>(_ groups: [Group<T>], _ name: String, _ group: String?) -> (Int, Int)? {
        for (gi, g) in groups.enumerated() where group == nil || g.name == group {
            if let ii = g.items.firstIndex(where: { $0.presetName == name }) { return (gi, ii) }
        }
        return nil
    }

    /// `base`, or `base 2`, `base 3`… so names stay unique across all groups (Photoshop allows
    /// duplicates, but agents address presets by name).
    static func uniqueName<T: Named>(_ groups: [Group<T>], _ base: String) -> String {
        func taken(_ n: String) -> Bool { groups.contains { $0.items.contains { $0.presetName == n } } }
        if !taken(base) { return base }
        var i = 2
        while taken("\(base) \(i)") { i += 1 }
        return "\(base) \(i)"
    }

    /// Index of `group` (created at the end when missing), or the first group (created as
    /// "Presets" when there is none).
    static func groupIndex<T>(_ groups: inout [Group<T>], _ group: String?) -> Int {
        if let n = group {
            if let i = groups.firstIndex(where: { $0.name == n }) { return i }
            groups.append(Group(n, []))
            return groups.count - 1
        }
        if groups.isEmpty { groups.append(Group("Presets", [])) }
        return 0
    }

    /// A group name not taken yet: `base`, else `base 1`, `base 2`…
    static func uniqueGroup<T>(_ groups: [Group<T>], _ base: String) -> String {
        func taken(_ n: String) -> Bool { groups.contains { $0.name == n } }
        if !taken(base) { return base }
        var i = 1
        while taken("\(base) \(i)") { i += 1 }
        return "\(base) \(i)"
    }

    /// Generic group/item edits shared by every preset kind: `rename`, `delete`, `move`,
    /// `newGroup`, `renameGroup`, `deleteGroup`.
    static func editGroups<T: Named>(_ groups: inout [Group<T>], _ action: String, _ p: JSONValue, _ cmd: String) throws -> JSONValue {
        let group = strParam(p, "group")
        switch action {
        case "rename":
            let name = try reqStr(p, "preset", cmd)
            let to = try reqStr(p, "name", cmd)
            guard let (gi, ii) = find(groups, name, group) else { throw EngineError.bad(cmd, "no preset \"\(name)\"") }
            if name != to && find(groups, to, nil) != nil { throw EngineError.bad(cmd, "a preset named \"\(to)\" already exists") }
            groups[gi].items[ii].presetName = to
            return ["name": .string(to)]
        case "delete":
            var names: [String]
            if case .array(let a)? = p["preset"] {
                names = a.compactMap(\.stringValue)
            } else {
                names = [try reqStr(p, "preset", cmd)]
            }
            // All or nothing: a missing name deletes none of the others.
            if let missing = names.first(where: { find(groups, $0, group) == nil }) { throw EngineError.bad(cmd, "no preset \"\(missing)\"") }
            names = Array(Set(names)).sorted()
            for n in names {
                if let (gi, ii) = find(groups, n, group), gi < groups.count, ii < groups[gi].items.count { groups[gi].items.remove(at: ii) }
            }
            return ["deleted": .int(names.count)]
        case "move":
            let name = try reqStr(p, "preset", cmd)
            let to = try reqStr(p, "to", cmd)
            guard let (gi, ii) = find(groups, name, group) else { throw EngineError.bad(cmd, "no preset \"\(name)\"") }
            let item = groups[gi].items.remove(at: ii)
            let ti = groupIndex(&groups, to)
            let n = groups[ti].items.count
            let at = p["index"]?.uint64Value.map { min(Int(clamping: $0), n) } ?? n
            groups[ti].items.insert(item, at: at)
            return ["group": .string(to)]
        case "newGroup":
            let base = strParam(p, "name") ?? "Group"
            let name = uniqueGroup(groups, base)
            groups.append(Group(name, []))
            return ["group": .string(name)]
        case "renameGroup":
            let g = try reqStr(p, "group", cmd)
            let to = try reqStr(p, "name", cmd)
            guard let i = groups.firstIndex(where: { $0.name == g }) else { throw EngineError.bad(cmd, "no group \"\(g)\"") }
            groups[i].name = to
            return ["group": .string(to)]
        case "deleteGroup":
            let g = try reqStr(p, "group", cmd)
            guard let i = groups.firstIndex(where: { $0.name == g }) else { throw EngineError.bad(cmd, "no group \"\(g)\"") }
            let removed = groups.remove(at: i)
            return ["group": .string(g), "deleted": .int(removed.items.count)]
        default:
            throw EngineError.bad(cmd, "unknown action \(action)")
        }
    }

    /// Params doc for the generic group commands.
    static let groupEditParams =
        ##"{"action":"rename|delete|move|newGroup|renameGroup|deleteGroup","preset":name|[names] (rename/delete/move),"group":name? (narrows the lookup; the group for renameGroup/deleteGroup),"name":str (rename: new name; newGroup/renameGroup: group name),"to":group (move),"index":n? (move)}"##

    /// photocraft `presets::call`: runs another command's implementation from inside a preset
    /// command (checks its precondition, but doesn't journal it: the outer command is what an
    /// action replays).
    static func call(_ s: Session, _ id: String, _ p: JSONValue) throws -> JSONValue {
        guard let spec = s.registry.spec(id) else { throw EngineError.unknownCommand(id) }
        if let r = spec.availability.reason { throw EngineError.unavailable(id, r) }
        if let why = spec.enabled(s, p) { throw EngineError.disabled(id, why) }
        return try spec.run(s, p)
    }

    /// `a` sorted by `key`, ties in their original order (Rust's stable `sort_by`).
    static func stableSorted<T>(_ a: [T], by key: (T) -> Float) -> [T] {
        a.enumerated().sorted { key($0.element) != key($1.element) ? key($0.element) < key($1.element) : $0.offset < $1.offset }.map(\.element)
    }

    static func clamp01(_ v: Float) -> Float { min(max(v, 0), 1) }

    // MARK: - Gradients

    /// A stop colour: fixed, or the current foreground/background colour. JSON (serde):
    /// `"foreground"`, `"background"` or `{"rgb":[r,g,b]}`.
    enum StopColor: Hashable, Sendable, Codable {
        case foreground
        case background
        case rgb(SIMD3<Float>)

        private enum K: String, CodingKey { case rgb }

        init(from decoder: any Decoder) throws {
            if let c = try? decoder.singleValueContainer(), let s = try? c.decode(String.self) {
                switch s {
                case "foreground": self = .foreground
                case "background": self = .background
                default: throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "unknown stop colour \(s)"))
                }
                return
            }
            let k = try decoder.container(keyedBy: K.self)
            let v = try k.decode([Float].self, forKey: .rgb)
            guard v.count == 3 else { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "rgb needs 3 values")) }
            self = .rgb(SIMD3(v[0], v[1], v[2]))
        }

        func encode(to encoder: any Encoder) throws {
            switch self {
            case .foreground:
                var c = encoder.singleValueContainer()
                try c.encode("foreground")
            case .background:
                var c = encoder.singleValueContainer()
                try c.encode("background")
            case .rgb(let v):
                var k = encoder.container(keyedBy: K.self)
                try k.encode([v.x, v.y, v.z], forKey: .rgb)
            }
        }
    }

    /// A colour stop of a preset: location 0...1 and a stop colour. JSON: `[location, colour]`.
    struct GradientStop: Hashable, Sendable, Codable {
        var location: Float
        var color: StopColor
        init(_ location: Float, _ color: StopColor) { self.location = location; self.color = color }
        init(from decoder: any Decoder) throws {
            var c = try decoder.unkeyedContainer()
            location = try c.decode(Float.self)
            color = try c.decode(StopColor.self)
        }
        func encode(to encoder: any Encoder) throws {
            var c = encoder.unkeyedContainer()
            try c.encode(location)
            try c.encode(color)
        }
    }

    /// A gradient preset: colour stops (fixed or live foreground/background colours) and
    /// transparency stops, both at `0...1`. Midpoints are always 50 %.
    struct GradientPreset: Hashable, Sendable, Codable, Named {
        var name: String
        /// Colour stops, sorted by location.
        var stops: [GradientStop]
        /// Transparency stops (location, opacity 0...1); empty = opaque.
        var opacity: [OpacityStop]

        var presetName: String {
            get { name }
            set { name = newValue }
        }

        init(name: String, stops: [GradientStop], opacity: [OpacityStop] = []) {
            self.name = name; self.stops = stops; self.opacity = opacity
        }

        enum CodingKeys: String, CodingKey { case name, stops, opacity }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            stops = try c.decode([GradientStop].self, forKey: .stops)
            opacity = try c.decodeIfPresent([OpacityStop].self, forKey: .opacity) ?? []
        }

        /// Evenly spaced colours.
        init(_ name: String, _ colors: [String]) {
            let n = Float(max(colors.count, 2) - 1)
            self.init(name: name, stops: colors.enumerated().map { GradientStop(Float($0.offset) / n, .rgb(PresetCommands.hex($0.element))) })
        }

        static let foregroundToBackground = GradientPreset(name: "Foreground to Background", stops: [GradientStop(0, .foreground), GradientStop(1, .background)])

        /// RGBA stops for painting: colour and transparency stops merged (see `applyOpacity`).
        func resolve(_ fg: SIMD4<Float>, _ bg: SIMD4<Float>) -> [(Float, SIMD4<Float>)] {
            func rgb(_ c: StopColor) -> SIMD4<Float> {
                switch c {
                case .foreground: SIMD4(fg.x, fg.y, fg.z, 1)
                case .background: SIMD4(bg.x, bg.y, bg.z, 1)
                case .rgb(let v): SIMD4(v, 1)
                }
            }
            var cs = PresetCommands.stableSorted(stops.map { (PresetCommands.clamp01($0.location), rgb($0.color)) }, by: \.0)
            if cs.isEmpty { cs = [(0, SIMD4(fg.x, fg.y, fg.z, 1)), (1, SIMD4(bg.x, bg.y, bg.z, 1))] }
            return PresetCommands.applyOpacity(cs, opacity)
        }

        /// Colour stops (live colours resolved now, sorted, opaque) and opacity stops (sorted;
        /// empty when fully opaque) kept apart, as an editable Gradient Fill layer holds them.
        func fillStops(_ fg: SIMD4<Float>, _ bg: SIMD4<Float>) -> ([ColorStop], [OpacityStop]) {
            func rgb(_ c: StopColor) -> PCColor {
                switch c {
                case .foreground: .rgb(fg.x, fg.y, fg.z)
                case .background: .rgb(bg.x, bg.y, bg.z)
                case .rgb(let v): .rgb(v.x, v.y, v.z)
                }
            }
            var cs = PresetCommands.stableSorted(stops.map { ColorStop(PresetCommands.clamp01($0.location), rgb($0.color)) }, by: \.location)
            if cs.isEmpty { cs = [ColorStop(0, rgb(.foreground)), ColorStop(1, rgb(.background))] }
            var os = PresetCommands.stableSorted(opacity.map { OpacityStop(PresetCommands.clamp01($0.location), PresetCommands.clamp01($0.opacity)) },
                                                 by: \.location)
            if os.allSatisfy({ abs($0.opacity - 1) < 1e-6 }) { os.removeAll() }
            return (cs, os)
        }

        /// Stops for a Gradient Fill layer / overlay (live colours resolved now, like Photoshop).
        func docStops(_ fg: SIMD4<Float>, _ bg: SIMD4<Float>) -> [ColorStop] {
            resolve(fg, bg).map { ColorStop($0.0, .rgb($0.1.x, $0.1.y, $0.1.z, $0.1.w)) }
        }

        var json: JSONValue {
            let st: [JSONValue] = stops.map { s in
                switch s.color {
                case .foreground: [.float(s.location), "foreground"]
                case .background: [.float(s.location), "background"]
                case .rgb(let c): [.float(s.location), .string(PresetCommands.hexOf(c))]
                }
            }
            let op: [JSONValue] = opacity.map { [.float($0.location), .float(($0.opacity * 100).rounded())] }
            return ["name": .string(name), "stops": .array(st), "transparency": .array(op)]
        }

        /// photocraft `from_params`: `{"stops":[[t,"#hex"|"foreground"|"background"],…],
        /// "transparency":[[t,0..100],…]}`.
        static func fromParams(_ name: String, _ p: JSONValue, _ cmd: String) throws -> GradientPreset {
            guard let arr = p["stops"]?.arrayValue else { throw EngineError.bad(cmd, "missing `stops`") }
            var stops: [GradientStop] = []
            for (i, s) in arr.enumerated() {
                var t: Float?, c: String?
                switch s {
                case .array(let a) where a.count == 2:
                    t = a[0].doubleValue.map { Float($0) }
                    c = a[1].stringValue
                case .string(let x):
                    t = arr.count > 1 ? Float(i) / Float(arr.count - 1) : 0
                    c = x
                default:
                    break
                }
                guard let t, let c else { throw EngineError.bad(cmd, ##"stops are [location, "#rrggbb"|"foreground"|"background"]"##) }
                stops.append(GradientStop(PresetCommands.clamp01(t), try PresetCommands.stopColor(c, cmd)))
            }
            if stops.count < 2 { throw EngineError.bad(cmd, "a gradient needs at least 2 colour stops") }
            return try GradientPreset(name: name, stops: PresetCommands.stableSorted(stops, by: \.location)).withTransparency(p, cmd)
        }

        /// This gradient with its transparency stops replaced by explicit `"transparency"` stops,
        /// when `p` has them (see `transparencyParam`).
        func withTransparency(_ p: JSONValue, _ cmd: String) throws -> GradientPreset {
            var g = self
            if let o = try PresetCommands.transparencyParam(p, cmd) { g.opacity = o }
            return g
        }
    }

    /// `"#rrggbb"`'s components (unparseable pairs 0).
    static func hex(_ s: String) -> SIMD3<Float> {
        let b = LayerStyleCommands.hexBytes(s)
        func c(_ i: Int) -> Float { LayerStyleCommands.hexPair(b, i).map { Float($0) / 255 } ?? 0 }
        return SIMD3(c(0), c(2), c(4))
    }

    static func hexOf(_ c: SIMD3<Float>) -> String {
        func q(_ v: Float) -> Int { Int((clamp01(v) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", q(c.x), q(c.y), q(c.z))
    }

    /// Whether `s` (leading `#`s removed) is six ASCII hex digits.
    static func isHex6(_ s: String) -> Bool {
        let b = LayerStyleCommands.hexBytes(s)
        return b.count == 6 && b.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }
    }

    /// A preset stop colour from its string form.
    static func stopColor(_ s: String, _ cmd: String) throws -> StopColor {
        switch s {
        case "foreground": return .foreground
        case "background": return .background
        case let h where isHex6(h): return .rgb(hex(h))
        default: throw EngineError.bad(cmd, "bad stop colour `\(s)`")
        }
    }

    static func lerp4(_ a: SIMD4<Float>, _ b: SIMD4<Float>, _ t: Float) -> SIMD4<Float> { a + (b - a) * t }

    /// Piecewise-linear value of sorted `(t, v)` stops at `t` (clamped at the ends).
    static func sample<V>(_ stops: [(Float, V)], _ t: Float, _ mix: (V, V, Float) -> V) -> V? {
        guard let first = stops.first else { return nil }
        if t <= first.0 { return first.1 }
        for i in 0..<(stops.count - 1) {
            let ((t0, a), (t1, b)) = (stops[i], stops[i + 1])
            if t <= t1 { return mix(a, b, t1 > t0 ? (t - t0) / (t1 - t0) : 1) }
        }
        return stops.last?.1
    }

    /// Sorted RGBA colour stops `cs` with transparency stops multiplied into their alpha. Where
    /// both vary, extra samples keep the product close to the reference app's per-pixel
    /// interpolation.
    static func applyOpacity(_ cs: [(Float, SIMD4<Float>)], _ opacity: [OpacityStop]) -> [(Float, SIMD4<Float>)] {
        let os = stableSorted(opacity.map { (clamp01($0.location), clamp01($0.opacity)) }, by: \.0)
        if os.isEmpty || os.allSatisfy({ abs($0.1 - 1) < 1e-6 }) { return cs }
        var ts = (cs.map(\.0) + os.map(\.0) + [0, 1]).sorted()
        var dedup: [Float] = []
        for t in ts where !(dedup.last.map { abs(t - $0) < 1e-6 } ?? false) { dedup.append(t) }
        ts = dedup
        var all: [Float] = []
        if ts.count >= 2 {
            for i in 0..<(ts.count - 1) {
                for k in 0..<4 { all.append(ts[i] + (ts[i + 1] - ts[i]) * Float(k) / 4) }
            }
        }
        all.append(1)
        return all.map { t in
            var c = sample(cs, t, lerp4) ?? .zero
            c.w *= sample(os, t) { a, b, u in a + (b - a) * u } ?? 1
            return (t, c)
        }
    }

    /// Explicit `"transparency":[[location 0..1, opacity 0..100], …]` as sorted stops (`[]` =
    /// opaque); nil when `p` has none.
    static func transparencyParam(_ p: JSONValue, _ cmd: String) throws -> [OpacityStop]? {
        guard let v = p["transparency"] else { return nil }
        guard let arr = v.arrayValue else { throw EngineError.bad(cmd, "`transparency` is [[location, opacity %], …]") }
        if arr.count > 1024 { throw EngineError.bad(cmd, "too many opacity stops (max 1024)") }
        var stops: [OpacityStop] = []
        for s in arr {
            guard let pair = s.arrayValue, pair.count == 2 else { throw EngineError.bad(cmd, "an opacity stop is [location 0..1, opacity 0..100]") }
            func f(_ i: Int) -> Float? { pair[i].doubleValue.map { Float($0) }.flatMap { $0.isFinite ? $0 : nil } }
            guard let t = f(0), let o = f(1) else { throw EngineError.bad(cmd, "opacity stops are numbers") }
            stops.append(OpacityStop(clamp01(t), clamp01(o / 100)))
        }
        return stableSorted(stops, by: \.location)
    }

    /// Built-in groups, laid out like Photoshop's default Gradients panel (Basics, then folders by
    /// hue). The colours are photocraft's own.
    static func builtinGradients() -> [Group<GradientPreset>] {
        func fam(_ prefix: String, _ sets: [[String]]) -> [GradientPreset] {
            sets.enumerated().map { GradientPreset("\(prefix) \($0.offset < 9 ? "0" : "")\($0.offset + 1)", $0.element) }
        }
        let fgTransparent = GradientPreset(name: "Foreground to Transparent", stops: [GradientStop(0, .foreground), GradientStop(1, .foreground)],
                                           opacity: [OpacityStop(0, 1), OpacityStop(1, 0)])
        // A smooth spectrum: 13 hues evenly spaced from red (0°) to magenta (300°).
        let rainbow = GradientPreset("Rainbow", ["#ec1313", "#ec6d13", "#ecc813", "#b6ec13", "#5bec13", "#13ec25", "#13ec80", "#13ecda", "#13a4ec",
                                                 "#1349ec", "#3713ec", "#9213ec", "#ec13ec"])
        var rainbowFade = rainbow
        rainbowFade.name = "Rainbow Fade"
        rainbowFade.opacity = [OpacityStop(0, 0), OpacityStop(0.125, 1), OpacityStop(0.875, 1), OpacityStop(1, 0)]
        return [
            Group("Basics", [.foregroundToBackground, fgTransparent, GradientPreset("Black, White", ["#000000", "#ffffff"])]),
            Group("Blues", fam("Blue", [["#0b3d91", "#4fa3e0"], ["#1c2a5a", "#3f6fd8", "#a8d4ff"], ["#00b4d8", "#03045e"], ["#5ec8f2", "#e6f6ff"],
                                        ["#253b80", "#20b2aa"], ["#89c2ff", "#1d4ed8", "#0a1a40"]])),
            Group("Purples", fam("Purple", [["#3c096c", "#c77dff"], ["#5a189a", "#e0aaff"], ["#240046", "#7b2cbf", "#f3d9ff"], ["#9d4edd", "#4361ee"],
                                            ["#6a0572", "#ab83a1"], ["#2d0b59", "#ff6fd8"]])),
            Group("Pinks", fam("Pink", [["#ff4d8d", "#ffd1e1"], ["#c9184a", "#ff8fab"], ["#ff70a6", "#ffd670"], ["#8e2c5a", "#f7a1c4", "#fff0f5"],
                                        ["#ff5fa2", "#a855f7"], ["#ffc2d6", "#ff2e63"]])),
            Group("Reds", fam("Red", [["#7f0000", "#ff3b30"], ["#d00000", "#ffba08"], ["#370617", "#9d0208", "#f48c06"], ["#e5383b", "#f5f3f4"],
                                      ["#a4161a", "#0b090a"], ["#ff595e", "#ffca3a"]])),
            Group("Oranges", fam("Orange", [["#ff6d00", "#ffd60a"], ["#e85d04", "#ffba08"], ["#9c3d0b", "#ff9e40", "#fff1d6"], ["#ff7b00", "#ff0054"],
                                            ["#fb8500", "#023047"], ["#ffb703", "#fb5607"]])),
            Group("Greens", fam("Green", [["#004b23", "#70e000"], ["#2d6a4f", "#b7e4c7"], ["#1b4332", "#40916c", "#d8f3dc"], ["#38b000", "#ccff33"],
                                          ["#0b6e4f", "#08a0a8"], ["#606c38", "#dda15e"]])),
            Group("Browns", fam("Brown", [["#3e2412", "#a47148"], ["#6f4518", "#e6ccb2"], ["#2b1708", "#7f5539", "#ddb892"], ["#8b5e34", "#ffd8a8"],
                                          ["#582f0e", "#b6ad90"], ["#4a3728", "#c08552", "#f3e9dc"]])),
            Group("Grays", fam("Gray", [["#212529", "#f8f9fa"], ["#495057", "#dee2e6"], ["#000000", "#6c757d", "#ffffff"], ["#343a40", "#adb5bd", "#343a40"],
                                        ["#8d99ae", "#2b2d42"], ["#e9ecef", "#ced4da", "#868e96"]])),
            Group("Rainbows", [
                rainbow,
                GradientPreset("Pastel Rainbow", ["#f4afaf", "#f4cbaf", "#f4e8af", "#e2f4af", "#c6f4af", "#aff4b4", "#aff4d1", "#aff4ee", "#afddf4",
                                                  "#afc0f4", "#baaff4", "#d7aff4", "#f4aff4"]),
                GradientPreset("Neon Rainbow", ["#ff0000", "#ff6a00", "#ffd400", "#bfff00", "#55ff00", "#00ff15", "#00ff80", "#00ffea", "#00aaff",
                                                "#0040ff", "#2a00ff", "#9500ff", "#ff00ff"]),
                GradientPreset("Oil Slick", ["#0b0f1a", "#1b2a4a", "#0f6f6f", "#1fae8a", "#5ac8a8", "#7a5cff", "#b13bd6", "#e04a8f", "#f2a65a", "#3a2a6b",
                                             "#0b0f1a"]),
                rainbowFade,
            ]),
        ]
    }

    // MARK: Gradient commands

    static let gradientSelect = "gradient.presets.select"
    /// The Gradient tool's current gradient, as a one-stop edit target.
    static let gradientStop = "gradient.presets.stop"

    /// photocraft `tool_stops`: the gradient the Gradient tool paints (`paint.gradient`):
    /// `"gradient": preset name`, else explicit `"stops"`, else the current gradient; explicit
    /// `"transparency"` stops replace its own. nil when the caller gave `colors` (the legacy evenly
    /// spaced form `paint.gradient` handles itself).
    static func toolStops(_ s: Session, _ p: JSONValue) throws -> [(Float, SIMD4<Float>)]? {
        let cmd = "paint.gradient"
        if let a = p["colors"]?.arrayValue, !a.isEmpty { return nil }
        let st = state(s)
        let g: GradientPreset
        if let name = strParam(p, "gradient") {
            guard let (gi, ii) = find(st.gradients, name, nil) else { throw EngineError.bad(cmd, "no gradient preset \"\(name)\"") }
            g = try st.gradients[gi].items[ii].withTransparency(p, cmd)
        } else if p["stops"] != nil {
            g = try GradientPreset.fromParams("Custom", p, cmd)
        } else {
            g = try st.gradient.withTransparency(p, cmd)
        }
        return g.resolve(s.tools.foreground, s.tools.background)
    }

    /// The preset named by `"preset"` (else the current gradient), or explicit `"stops"`.
    static func gradientParam(_ s: Session, _ p: JSONValue, _ cmd: String) throws -> GradientPreset {
        let st = state(s)
        if let name = strParam(p, "preset") {
            guard let (gi, ii) = find(st.gradients, name, strParam(p, "group")) else {
                throw EngineError.bad(cmd, "no gradient preset \"\(name)\" (see gradient.presets.list)")
            }
            return st.gradients[gi].items[ii]
        }
        if p["stops"] != nil { return try GradientPreset.fromParams(strParam(p, "name") ?? "Custom", p, cmd) }
        return st.gradient
    }

    static func gradientList(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let st = state(s)
        let groups: [JSONValue] = st.gradients.map { ["name": .string($0.name), "presets": .array($0.items.map(\.json))] }
        return ["groups": .array(groups), "current": st.gradient.json]
    }

    static func activeFill(_ s: Session, _ isKind: (Fill) -> Bool) -> LayerId? {
        guard let d = s.active, let id = d.activeLayer, let l = d.doc.layer(id), case .fill(let f) = l.content, isKind(f) else { return nil }
        return id
    }

    static func gradientSelectRun(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let g = try gradientParam(s, p, gradientSelect)
        s.state[Key.self].gradient = g
        presetsChanged(s)
        var out: [String: JSONValue] = ["current": g.json]
        // Clicking a preset with a Gradient Fill layer selected changes that layer (Photoshop).
        if p["applyToLayer"]?.boolValue ?? true, let id = activeFill(s, { if case .gradient = $0 { true } else { false } }) {
            let (stopsNew, opacityNew) = g.fillStops(s.tools.foreground, s.tools.background)
            try s.edit("Change Gradient Fill") { doc, _ in
                let mode = doc.mode
                doc.updateLayer(id) { l in
                    if case .fill(.gradient(var gf)) = l.content {
                        gf.stops = stopsNew.map { ColorStop($0.location, $0.color.converted(to: mode)) }
                        gf.opacityStops = opacityNew
                        gf.midpoints.removeAll()
                        l.content = .fill(.gradient(gf))
                    }
                }
            }
            out["layer"] = .id(id)
        }
        return .object(out)
    }

    /// A preset stop colour param: `"#rrggbb"`, `"foreground"` or `"background"`.
    static func stopColorParam(_ v: JSONValue, _ cmd: String) throws -> StopColor {
        guard let s = v.stringValue else { throw EngineError.bad(cmd, ##"a stop colour is "#rrggbb", "foreground" or "background""##) }
        return try stopColor(s, cmd)
    }

    /// photocraft `apply_preset_stop`: a `gradient.presets.stop` edit of the Gradient tool's
    /// current gradient (the `gradient.fill.stop` grammar without a layer; midpoints are refused,
    /// presets keep them centred). Pure, so the editor previews a drag with exactly what the
    /// command commits.
    static func applyPresetStop(_ g: GradientPreset, _ p: JSONValue, _ fg: SIMD4<Float>, _ bg: SIMD4<Float>, _ cmd: String) throws -> GradientPreset {
        var out = g
        guard let action = p["action"]?.stringValue else { throw EngineError.bad(cmd, "missing `action` (add|move|delete|color|opacity)") }
        if action == "midpoint" {
            throw EngineError.bad(cmd, "preset gradients keep midpoints at the centre (edit a Gradient Fill layer to move them)")
        }
        let opacityKind: Bool
        switch p["kind"]?.stringValue ?? "color" {
        case "color": opacityKind = false
        case "opacity": opacityKind = true
        case let o: throw EngineError.bad(cmd, "unknown kind `\(o)` (color|opacity)")
        }
        func index() throws -> Int {
            guard let v = p["index"]?.uint64Value, let i = Int(exactly: v) else { throw EngineError.bad(cmd, "missing `index` (a stop number from 0)") }
            return i
        }
        func location() throws -> Float {
            guard let v = p["location"]?.doubleValue.map({ Float($0) }), v.isFinite else { throw EngineError.bad(cmd, "missing `location` (0..1)") }
            return clamp01(v)
        }
        let ramp = g.resolve(fg, bg)
        if opacityKind {
            // Opacity stops: an empty list means "opaque" (two 100 % stops when first edited).
            var os = stableSorted(out.opacity.isEmpty ? [OpacityStop(0, 1), OpacityStop(1, 1)] : out.opacity, by: \.location)
            func opacity() throws -> Float {
                guard let v = p["opacity"]?.doubleValue else { throw EngineError.bad(cmd, "missing `opacity` (0..100)") }
                return clamp01(Float(v) / 100)
            }
            switch action {
            case "add":
                let t = try location()
                let a = p["opacity"] != nil ? try opacity() : (sample(ramp, t, lerp4)?.w ?? 1)
                os.append(OpacityStop(t, a))
            case "move":
                let i = try index(), t = try location()
                guard i < os.count else { throw EngineError.bad(cmd, "no opacity stop \(i)") }
                os[i].location = t
            case "delete":
                let i = try index()
                if i >= os.count { throw EngineError.bad(cmd, "no opacity stop \(i)") }
                if os.count <= 2 { throw EngineError.bad(cmd, "a gradient keeps at least 2 opacity stops") }
                os.remove(at: i)
            case "opacity":
                let i = try index(), a = try opacity()
                guard i < os.count else { throw EngineError.bad(cmd, "no opacity stop \(i)") }
                os[i].opacity = a
            default:
                throw EngineError.bad(cmd, "unknown action `\(action)` for opacity stops (add|move|delete|opacity)")
            }
            os = stableSorted(os, by: \.location)
            if os.count > 1024 { throw EngineError.bad(cmd, "too many opacity stops (max 1024)") }
            // Fully opaque again: store as no opacity stops, like `fillStops` reads them.
            if os.allSatisfy({ abs($0.opacity - 1) < 1e-6 }) { os.removeAll() }
            out.opacity = os
            return out
        }
        var stops = stableSorted(out.stops, by: \.location)
        switch action {
        case "add":
            let t = try location()
            // A new stop takes the colour the gradient has there (Photoshop), unless given.
            let c: StopColor
            if let v = p["color"] {
                c = try stopColorParam(v, cmd)
            } else {
                c = sample(ramp, t, lerp4).map { .rgb(SIMD3($0.x, $0.y, $0.z)) } ?? .rgb(.zero)
            }
            stops.append(GradientStop(t, c))
            if stops.count > 1024 { throw EngineError.bad(cmd, "too many colour stops (max 1024)") }
        case "move":
            let i = try index(), t = try location()
            guard i < stops.count else { throw EngineError.bad(cmd, "no colour stop \(i)") }
            stops[i].location = t
        case "delete":
            let i = try index()
            if i >= stops.count { throw EngineError.bad(cmd, "no colour stop \(i)") }
            if stops.count <= 2 { throw EngineError.bad(cmd, "a gradient keeps at least 2 colour stops") }
            stops.remove(at: i)
        case "color":
            let i = try index()
            guard let v = p["color"] else { throw EngineError.bad(cmd, "missing `color`") }
            let c = try stopColorParam(v, cmd)
            guard i < stops.count else { throw EngineError.bad(cmd, "no colour stop \(i)") }
            stops[i].color = c
        default:
            throw EngineError.bad(cmd, "unknown action `\(action)` (add|move|delete|color)")
        }
        out.stops = stableSorted(stops, by: \.location)
        return out
    }

    static func gradientStopRun(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let g = try applyPresetStop(state(s).gradient, p, s.tools.foreground, s.tools.background, gradientStop)
        s.state[Key.self].gradient = g
        presetsChanged(s)
        return ["current": g.json]
    }

    static func gradientApply(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "gradient.presets.apply"
        let g = try gradientParam(s, p, cmd)
        let stops = g.docStops(s.tools.foreground, s.tools.background)
        let angle = Float(p["angle"]?.doubleValue ?? 90)
        let scale = min(max(Float(p["scale"]?.doubleValue ?? 100) / 100, 0.1), 1.5)
        let style = LayerStyleCommands.gradientStyle(p["style"]?.stringValue ?? "linear")
        let reverse = p["reverse"]?.boolValue ?? false
        let id = try s.edit("New Gradient Fill Layer") { doc, active -> LayerId in
            let fill = Fill.gradient(GradientFill(stops: stops, angle: angle, scale: scale, style: style, reverse: reverse)).inMode(doc.mode)
            let id = doc.insertAbove(active, Layer(name: doc.nextLayerName("Gradient Fill"), content: .fill(fill)))
            active = id
            return id
        }
        return ["layer": .id(id), "preset": .string(g.name)]
    }

    static func gradientNew(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "gradient.presets.new"
        var g = p["stops"] != nil ? try GradientPreset.fromParams("", p, cmd) : state(s).gradient
        var st = state(s)
        g.name = uniqueName(st.gradients, strParam(p, "name") ?? "Custom")
        let gi = groupIndex(&st.gradients, strParam(p, "group"))
        st.gradients[gi].items.append(g)
        let group = st.gradients[gi].name
        s.state[Key.self] = st
        presetsChanged(s)
        return ["name": .string(g.name), "group": .string(group)]
    }

    static func gradientEdit(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "gradient.presets.edit"
        let action = try reqStr(p, "action", cmd)
        var groups = state(s).gradients
        let r = try editGroups(&groups, action, p, cmd)
        s.state[Key.self].gradients = groups
        presetsChanged(s)
        return r
    }

    static func gradientReset(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        var b = builtinGradients()
        var st = state(s)
        if p["append"]?.boolValue ?? false {
            for i in b.indices { b[i].name = uniqueGroup(st.gradients, b[i].name) }
            st.gradients += b
        } else {
            st.gradients = b
        }
        s.state[Key.self] = st
        presetsChanged(s)
        return ["groups": .int(st.gradients.count)]
    }

    static func gradientSpecs() -> [CommandSpec] {
        let stops = ##""stops":[[t 0..1,"#rrggbb"|"foreground"|"background"],…],"transparency":[[t,opacity 0..100],…]?"##
        return [
            CommandSpec("gradient.presets.list", "Gradient Presets", params: "{} → {groups:[{name,presets:[{name,stops,transparency}]}],current}",
                        module: m, journal: false, run: gradientList),
            CommandSpec(gradientSelect, "Select Gradient",
                        params: ##"{"preset":name|"## + stops + ##","group":name?,"applyToLayer":bool=true (also recolours a selected Gradient Fill layer)} → {current,layer?}. The Gradient tool paints with it."##,
                        module: m, run: gradientSelectRun),
            CommandSpec(gradientStop, "Edit Gradient Stop",
                        params: ##"{"action":"add|move|delete|color|opacity","kind":"color|opacity"="color","index":stop number,"location":0..1,"color":"#rrggbb"|"foreground"|"background" (add: default the colour there),"opacity":0..100} → {"current"}. Edits the Gradient tool's current gradient (no layer, midpoints stay centred)."##,
                        module: m, run: gradientStopRun),
            CommandSpec("gradient.presets.apply", "New Gradient Fill Layer from Preset",
                        params: ##"{"preset":name?=current|"## + stops + ##","angle":deg=90,"style":"linear|radial|angle|reflected|diamond"="linear","scale":10..150=100,"reverse":bool} → {layer}"##,
                        module: m, enabled: Pre.hasDoc, run: gradientApply),
            CommandSpec("gradient.presets.new", "New Gradient Preset",
                        params: ##"{"name":str="Custom","group":name?=first,"## + stops + ##" (default: the current gradient)}"##,
                        module: m, run: gradientNew),
            CommandSpec("gradient.presets.edit", "Edit Gradient Presets", params: groupEditParams, module: m, run: gradientEdit),
            CommandSpec("gradient.presets.reset", "Restore Default Gradients", params: ##"{"append":bool=false}"##, module: m, run: gradientReset),
        ]
    }

    // MARK: - Pattern folders

    static let ungrouped = "Patterns"

    /// Built-in folders for the built-in procedural patterns.
    static func builtinPatternGroups() -> [Group<PatternRef>] {
        let lib = PatternCommands.LibraryKey.defaultValue
        func ids(_ names: [String]) -> [PatternRef] { names.compactMap { n in lib.first { $0.name == n }.map { PatternRef($0.id) } } }
        return [Group("Geometric", ids(["Checkerboard", "Diagonal Lines", "Dots", "Grid"])), Group("Textures", ids(["Bricks", "Weave", "Paper Noise"]))]
    }

    /// photocraft `patterns::sync`: folders in line with the library. Ids whose pattern was
    /// deleted are dropped; library patterns in no folder (newly defined or imported) go to a
    /// trailing "Patterns" folder.
    static func syncPatternGroups(_ s: Session) {
        let lib = PatternCommands.library(s).map(\.id)
        var groups = state(s).patternGroups
        for i in groups.indices { groups[i].items.removeAll { !lib.contains($0.id) } }
        let loose = lib.filter { id in !groups.contains { $0.items.contains(PatternRef(id)) } }
        if !loose.isEmpty {
            let gi = groupIndex(&groups, ungrouped)
            groups[gi].items += loose.map(PatternRef.init)
        }
        s.state[Key.self].patternGroups = groups
    }

    /// The selected pattern, if it is still in the library.
    static func currentPattern(_ s: Session) -> Pattern? {
        guard let id = state(s).pattern else { return nil }
        return PatternCommands.library(s).first { $0.id == id }
    }

    static func patternList(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        syncPatternGroups(s)
        let lib = PatternCommands.library(s)
        let groups: [JSONValue] = state(s).patternGroups.map { g in
            let pats: [JSONValue] = g.items.compactMap { ref in lib.first { $0.id == ref.id } }.map {
                ["id": .string($0.id), "name": .string($0.displayName), "width": .int($0.width), "height": .int($0.height)]
            }
            return ["name": .string(g.name), "patterns": .array(pats)]
        }
        return ["groups": .array(groups), "current": currentPattern(s).map { .string($0.id) } ?? .null]
    }

    static func patternKey(_ s: Session, _ p: JSONValue, _ cmd: String) throws -> Pattern {
        let key = strParam(p, "pattern") ?? ""
        guard let pat = PatternCommands.resolve(s, key) else { throw EngineError.bad(cmd, "no pattern \"\(key)\" (see pattern.presets.list)") }
        return pat
    }

    static func patternSelect(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let pat = try patternKey(s, p, "pattern.presets.select")
        s.state[Key.self].pattern = pat.id
        s.state[Key.self].rev += 1
        var out: [String: JSONValue] = ["pattern": .string(pat.id), "name": .string(pat.displayName)]
        if p["applyToLayer"]?.boolValue ?? true, let id = activeFill(s, { if case .pattern = $0 { true } else { false } }) {
            try s.edit("Change Pattern Fill") { doc, _ in
                PatternCommands.ensureInDoc(&doc, pat)
                doc.updateLayer(id) { l in
                    if case .fill(.pattern(var pf)) = l.content {
                        pf.name = pat.name
                        pf.id = pat.id
                        l.content = .fill(.pattern(pf))
                    }
                }
            }
            out["layer"] = .id(id)
        }
        return .object(out)
    }

    static func patternApply(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let pat = try patternKey(s, p, "pattern.presets.apply")
        return try call(s, "layer.newFillLayer.pattern", p.setting("pattern", .string(pat.id)))
    }

    static func patternNew(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let r = try call(s, "edit.definePattern", p)
        let id = r["pattern"]?.stringValue ?? ""
        syncPatternGroups(s)
        if let g = strParam(p, "group") {
            var groups = state(s).patternGroups
            for i in groups.indices { groups[i].items.removeAll { $0.id == id } }
            let gi = groupIndex(&groups, g)
            groups[gi].items.append(PatternRef(id))
            s.state[Key.self].patternGroups = groups
        }
        presetsChanged(s)
        return ["pattern": .string(id)]
    }

    static func patternEdit(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "pattern.presets.edit"
        syncPatternGroups(s)
        let action = try reqStr(p, "action", cmd)
        let r: JSONValue
        switch action {
        // Rename/delete act on the library pattern (by id or name).
        case "rename":
            r = try call(s, "pattern.rename", ["pattern": .string(try reqStr(p, "preset", cmd)), "name": .string(try reqStr(p, "name", cmd))])
        case "delete":
            let keys: [String]
            if case .array(let a)? = p["preset"] { keys = a.compactMap(\.stringValue) } else { keys = [try reqStr(p, "preset", cmd)] }
            for k in keys { _ = try call(s, "pattern.delete", ["pattern": .string(k)]) }
            r = ["deleted": .int(keys.count)]
        case "deleteGroup":
            // Deleting a folder deletes its patterns, as in Photoshop.
            let g = try reqStr(p, "group", cmd)
            guard let i = state(s).patternGroups.firstIndex(where: { $0.name == g }) else { throw EngineError.bad(cmd, "no group \"\(g)\"") }
            let gone = s.state[Key.self].patternGroups.remove(at: i)
            s.state[PatternCommands.LibraryKey.self].removeAll { q in gone.items.contains { $0.id == q.id } }
            r = ["group": .string(g), "deleted": .int(gone.items.count)]
        case "move":
            let key = try reqStr(p, "preset", cmd)
            guard let id = PatternCommands.resolve(s, key)?.id else { throw EngineError.bad(cmd, "no pattern \"\(key)\"") }
            var groups = state(s).patternGroups
            r = try editGroups(&groups, "move", p.setting("preset", .string(id)), cmd)
            s.state[Key.self].patternGroups = groups
        default:
            var groups = state(s).patternGroups
            r = try editGroups(&groups, action, p, cmd)
            s.state[Key.self].patternGroups = groups
        }
        syncPatternGroups(s)
        presetsChanged(s)
        return r
    }

    static func patternSpecs() -> [CommandSpec] {
        [
            CommandSpec("pattern.presets.list", "Pattern Presets", params: "{} → {groups:[{name,patterns:[{id,name,width,height}]}],current}",
                        module: m, journal: false, run: patternList),
            CommandSpec("pattern.presets.select", "Select Pattern",
                        params: ##"{"pattern":id|name,"applyToLayer":bool=true (also changes a selected Pattern Fill layer)} (Fill and new Pattern Fill layers default to it)"##,
                        module: m, run: patternSelect),
            CommandSpec("pattern.presets.apply", "New Pattern Fill Layer from Preset",
                        params: ##"{"pattern":id|name?=selected,"scale":1..1000=100,"angle":deg=0} → {layer}"##,
                        module: m, enabled: Pre.hasDoc, run: patternApply),
            CommandSpec("pattern.presets.new", "New Pattern Preset",
                        params: ##"{"name":str?,"group":name?,"rect":[x0,y0,x1,y1]?} (Define Pattern from the selection/canvas into a group)"##,
                        module: m, enabled: Pre.hasDoc, run: patternNew),
            CommandSpec("pattern.presets.edit", "Edit Pattern Presets", params: groupEditParams, module: m, run: patternEdit),
        ]
    }
}
