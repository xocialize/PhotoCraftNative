// Port of photocraft-engine (crates/engine/src/document_preset_cmds.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Named New Document configurations and File › New › Recent. Selecting a preset only returns
// settings; document creation stays in `file.new`. The presets live in session state (`Key`); the
// app's preferences layer persists them with `value(_:)` / `restore(_:from:)` (photocraft keeps
// them under `presets.documents` and `presets.recent_documents` in its preferences JSON).

import Foundation
import PCDocument
import PCFoundation

enum DocumentPresetCommands: CommandModule {
    static let name = "document_preset_cmds"
    static let m = "document_preset_cmds"

    static let maxPresets = 256
    /// File › New › Recent keeps this many settings, like Photoshop's Recent tab.
    static let maxRecent = 20
    /// photocraft `brush_preset_cmds::MAX_NAME`.
    static let maxName = 255

    // MARK: Model

    /// One New Document configuration. Width and height are always pixels and resolution ppi;
    /// `unit` and `resolutionUnit` are display units only.
    struct Settings: Equatable, Sendable {
        var width: UInt32
        var height: UInt32
        var resolution: Float
        var mode: String
        var depth: UInt8
        var background: String
        var backgroundColor: SIMD3<Float>?
        var unit: String
        var resolutionUnit: String

        func validate() -> String? {
            let maxDim = UInt32(CoreCommands.maxDimension)
            if !(1...maxDim).contains(width) || !(1...maxDim).contains(height) {
                return "Width and height must be within 1..=\(maxDim) pixels"
            }
            if !resolution.isFinite || !(1...Float(CoreCommands.maxResolution)).contains(resolution) {
                return "Resolution must be within 1..=\(Int(CoreCommands.maxResolution)) ppi"
            }
            if DocumentPresetCommands.colorMode(mode) == nil || CoreCommands.sampleType(Int(depth)) == nil {
                return "Use RGB, Grayscale, CMYK or Lab at 8, 16 or 32 bits"
            }
            if !["white", "black", "transparent", "backgroundColor"].contains(background) && Params.parseHex(background) == nil {
                return "Unknown background choice or invalid colour"
            }
            if background == "backgroundColor" && backgroundColor == nil { return "A saved Background Color needs its colour value" }
            if let c = backgroundColor, ![c.x, c.y, c.z].allSatisfy({ $0.isFinite && (0...1).contains($0) }) {
                return "Background colour components must be within 0..1"
            }
            if !["px", "in", "cm", "mm", "pt", "pica"].contains(unit) || !["in", "cm"].contains(resolutionUnit) {
                return "Unknown dimension or resolution display unit"
            }
            return nil
        }

        /// Creation params: deliberately without the preset name and the display-only units.
        var commandParams: JSONValue {
            var p: JSONValue = ["width": .int(width), "height": .int(height), "resolution": .float(resolution), "mode": .string(mode),
                                "depth": .int(depth), "background": .string(background)]
            if let c = backgroundColor { p = p.setting("backgroundColor", .floats([c.x, c.y, c.z])) }
            return p
        }

        /// serde's form (camelCase, `backgroundColor` omitted when unset).
        var json: JSONValue {
            var p = commandParams
            p = p.setting("unit", .string(unit)).setting("resolutionUnit", .string(resolutionUnit))
            return p
        }

        /// serde's `Deserialize` (unknown fields ignored; a type mismatch is the error text).
        static func decode(_ v: JSONValue) -> Result<Settings, DecodeError> {
            guard let o = v.objectValue else { return .failure(DecodeError("invalid type: \(kind(v)), expected struct DocumentSettings")) }
            func field(_ k: String) throws(DecodeError) -> JSONValue {
                guard let f = o[k] else { throw DecodeError("missing field `\(k)`") }
                return f
            }
            func uint(_ k: String, _ maxV: Double, _ ty: String) throws(DecodeError) -> Double {
                let f = try field(k)
                guard case .number(let n) = f else { throw DecodeError("invalid type: \(kind(f)), expected \(ty)") }
                guard n.isFinite, n == n.rounded() else { throw DecodeError("invalid type: floating point `\(n)`, expected \(ty)") }
                guard n >= 0, n <= maxV else { throw DecodeError("invalid value: integer `\(Int64(n))`, expected \(ty)") }
                return n
            }
            func string(_ k: String) throws(DecodeError) -> String {
                let f = try field(k)
                guard let s = f.stringValue else { throw DecodeError("invalid type: \(kind(f)), expected a string") }
                return s
            }
            do throws(DecodeError) {
                let width = try uint("width", Double(UInt32.max), "u32")
                let height = try uint("height", Double(UInt32.max), "u32")
                let r = try field("resolution")
                guard case .number(let res) = r else { throw DecodeError("invalid type: \(kind(r)), expected f32") }
                let mode = try string("mode")
                let depth = try uint("depth", 255, "u8")
                let background = try string("background")
                var color: SIMD3<Float>?
                if let c = o["backgroundColor"], c != .null {
                    guard let a = c.arrayValue else { throw DecodeError("invalid type: \(kind(c)), expected an array of length 3") }
                    guard a.count == 3 else { throw DecodeError("invalid length \(a.count), expected an array of length 3") }
                    let f = a.compactMap(\.doubleValue)
                    guard f.count == 3 else { throw DecodeError("invalid type: expected f32") }
                    color = SIMD3(Float(f[0]), Float(f[1]), Float(f[2]))
                }
                let unit = try string("unit")
                let resolutionUnit = try string("resolutionUnit")
                return .success(Settings(width: UInt32(width), height: UInt32(height), resolution: Float(res), mode: mode, depth: UInt8(depth),
                                         background: background, backgroundColor: color, unit: unit, resolutionUnit: resolutionUnit))
            } catch {
                return .failure(error)
            }
        }

        static func kind(_ v: JSONValue) -> String {
            switch v {
            case .null: "null"
            case .bool(let b): "boolean `\(b)`"
            case .number(let n): "floating point `\(n)`"
            case .string(let s): "string \"\(s)\""
            case .array: "sequence"
            case .object: "map"
            }
        }

        /// photocraft `DocumentSettings::from_params`: documented defaults filled in, pixel counts
        /// sent as floats accepted, invalid input refused rather than saved differently.
        static func fromParams(_ s: Session, _ p: JSONValue, _ cmd: String) throws -> Settings {
            guard var fields = p.objectValue else { throw EngineError.bad(cmd, "`settings` must be an object") }
            let defaults: [String: JSONValue] = ["resolution": 72.0, "mode": "rgb", "depth": 8, "background": "white", "unit": "px", "resolutionUnit": "in"]
            for (k, v) in defaults where fields[k] == nil { fields[k] = v }
            for key in ["width", "height"] {
                guard let n = fields[key]?.doubleValue, n.isFinite, (1...Double(CoreCommands.maxDimension)).contains(n) else {
                    throw EngineError.bad(cmd, "`\(key)` must be within 1..=\(CoreCommands.maxDimension) pixels")
                }
                fields[key] = .number(n.rounded())
            }
            if fields["mode"]?.stringValue == "grayscale" { fields["mode"] = "gray" }
            if fields["background"]?.stringValue == "backgroundColor" {
                let c = try DocumentPresetCommands.backgroundColor(.object(fields), s.tools.background, cmd)
                fields["backgroundColor"] = .floats([c.x, c.y, c.z])
            }
            let settings: Settings
            switch decode(.object(fields)) {
            case .success(let v): settings = v
            case .failure(let e): throw EngineError.bad(cmd, "invalid settings: \(e.message)")
            }
            if let e = settings.validate() { throw EngineError.bad(cmd, e) }
            return settings
        }
    }

    struct DecodeError: Error, Sendable {
        var message: String
        init(_ m: String) { message = m }
    }

    struct Preset: Equatable, Sendable {
        var name: String
        var settings: Settings

        var json: JSONValue { ["name": .string(name), "settings": settings.json] }

        static func decode(_ v: JSONValue) -> Preset? {
            guard let o = v.objectValue, let name = o["name"]?.stringValue, let sv = o["settings"],
                  case .success(let settings) = Settings.decode(sv) else { return nil }
            return Preset(name: name, settings: settings)
        }
    }

    /// Session state (photocraft `Session::presets.documents` / `.recent_documents`).
    struct Store: Sendable {
        var documents: [Preset] = []
        var recent: [Settings] = []
        /// Bumped on every change (photocraft `presets_changed` marks preferences dirty).
        var revision: UInt64 = 0
    }

    enum Key: StateKey { static let defaultValue = Store() }

    // MARK: Validation

    /// The formats accepted by `file.new` (photocraft `color_mode`: lower-case names only).
    static func colorMode(_ mode: String) -> ColorMode? {
        switch mode {
        case "rgb": .rgb
        case "gray", "grayscale": .grayscale
        case "cmyk": .cmyk
        case "lab": .lab
        default: nil
        }
    }

    /// A saved Background Color must not follow later changes to the toolbox colour.
    static func backgroundColor(_ p: JSONValue, _ fallback: SIMD4<Float>, _ cmd: String) throws -> SIMD4<Float> {
        let msg = "`backgroundColor` must be [r,g,b] in 0..1"
        let c: [Float]
        if let v = p["backgroundColor"] {
            guard let a = v.arrayValue, a.count == 3 else { throw EngineError.bad(cmd, msg) }
            let f = a.compactMap(\.doubleValue)
            guard f.count == 3 else { throw EngineError.bad(cmd, msg) }
            c = f.map { Float($0) }
        } else {
            c = [fallback.x, fallback.y, fallback.z]
        }
        if !c.allSatisfy({ $0.isFinite && (0...1).contains($0) }) { throw EngineError.bad(cmd, msg) }
        return SIMD4(c[0], c[1], c[2], 1)
    }

    /// photocraft `validate_new_params`: validates File › New's params before dispatch can commit
    /// a floating selection or add a document. Missing fields keep the documented defaults;
    /// unknown fields and an invalid `backgroundColor` are refused. (`CoreCommands.validateNew`
    /// is the core's version, which checks less; `file.new` should call this one.)
    static func validateNewParams(_ s: Session, _ p: JSONValue) throws {
        let cmd = "file.new"
        if p == .null { return }
        guard let fields = p.objectValue else { throw EngineError.bad(cmd, "params must be a JSON object") }
        for key in fields.keys.sorted() {
            guard let value = fields[key] else { continue }
            let valid: Bool, expected: String
            switch key {
            case "width", "height", "resolution":
                let maxV = key == "resolution" ? CoreCommands.maxResolution : Double(CoreCommands.maxDimension)
                valid = value.doubleValue.map { $0.isFinite && (1...maxV).contains($0) } ?? false
                expected = "a number within 1..=\(Int(maxV))"
            case "mode":
                valid = value.stringValue.flatMap(colorMode) != nil
                expected = "rgb, gray, grayscale, cmyk or lab"
            case "depth":
                valid = value.uint64Value.flatMap { CoreCommands.sampleType(Int(clamping: $0)) } != nil
                expected = "8, 16 or 32"
            case "background":
                valid = value.stringValue.map { v in
                    ["white", "black", "transparent", "backgroundColor"].contains(v)
                        || ((v.hasPrefix("#") ? v.dropFirst() : Substring(v)).allSatisfy(\.isHexDigit) && Params.parseHex(v) != nil)
                } ?? false
                expected = "white, black, transparent, backgroundColor or a valid hex colour"
            case "backgroundColor":
                _ = try backgroundColor(p, s.tools.background, cmd)
                continue
            case "name":
                valid = value.stringValue != nil
                expected = "a string"
            default:
                throw EngineError.bad(cmd, "unknown parameter `\(key)`")
            }
            if !valid { throw EngineError.bad(cmd, "`\(key)` must be \(expected)") }
        }
        if p["background"]?.stringValue == "backgroundColor" { _ = try backgroundColor(p, s.tools.background, cmd) }
    }

    static func checkedName(_ name: String) -> Result<String, DecodeError> {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if n.isEmpty || n.unicodeScalars.count > maxName { return .failure(DecodeError("Preset names must contain 1–255 characters after trimming")) }
        return .success(n)
    }

    /// presets `req_str`: a trimmed, non-empty string.
    static func reqStr(_ p: JSONValue, _ k: String, _ cmd: String) throws -> String {
        guard let v = p[k]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { throw EngineError.bad(cmd, "missing `\(k)`") }
        return v
    }

    // MARK: Persistence

    /// Reads stored presets entry by entry, so a damaged preset can't discard the others.
    static func load(_ value: JSONValue) -> [Preset] {
        guard let entries = value.arrayValue else { return [] }
        var presets: [Preset] = []
        for entry in entries.prefix(maxPresets) {
            guard var preset = Preset.decode(entry), case .success(let name) = checkedName(preset.name) else { continue }
            if preset.settings.validate() != nil || presets.contains(where: { ArtboardCommands.asciiLower($0.name) == ArtboardCommands.asciiLower(name) }) { continue }
            preset.name = name
            if preset.settings.mode == "grayscale" { preset.settings.mode = "gray" }
            presets.append(preset)
        }
        return presets
    }

    /// Reads the Recent list like `load`: a damaged entry is dropped, the rest kept, newest first.
    static func loadRecent(_ value: JSONValue) -> [Settings] {
        guard let entries = value.arrayValue else { return [] }
        var recent: [Settings] = []
        for entry in entries {
            guard case .success(var settings) = Settings.decode(entry) else { continue }
            if settings.mode == "grayscale" { settings.mode = "gray" }
            if settings.validate() != nil || recent.contains(where: { $0.commandParams == settings.commandParams }) { continue }
            recent.append(settings)
            if recent.count >= maxRecent { break }
        }
        return recent
    }

    /// The presets as photocraft's preferences store them (`{"documents", "recent_documents"}`).
    static func value(_ s: Session) -> JSONValue {
        let st = s.state[Key.self]
        return ["documents": .array(st.documents.map(\.json)), "recent_documents": .array(st.recent.map(\.json))]
    }

    /// Restores presets saved with `value`; a missing or damaged collection loads empty.
    static func restore(_ s: Session, from v: JSONValue) {
        var st = s.state[Key.self]
        st.documents = load(v["documents"] ?? .null)
        st.recent = loadRecent(v["recent_documents"] ?? .null)
        s.state[Key.self] = st
    }

    static func changed(_ s: Session) {
        s.state[Key.self].revision += 1
        s.emit(.preferencesChanged)
    }

    // MARK: Commands

    static func addRecent(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let settings = try Settings.fromParams(s, p["settings"] ?? .null, "document.recent.add")
        var st = s.state[Key.self]
        st.recent.removeAll { $0.commandParams == settings.commandParams }
        st.recent.insert(settings, at: 0)
        if st.recent.count > maxRecent { st.recent.removeSubrange(maxRecent...) }
        s.state[Key.self] = st
        changed(s)
        return ["recent": .array(st.recent.map(\.json))]
    }

    static func save(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "document.presets.save"
        let name: String
        switch checkedName(try reqStr(p, "name", cmd)) {
        case .success(let n): name = n
        case .failure(let e): throw EngineError.bad(cmd, e.message)
        }
        let st = s.state[Key.self]
        if st.documents.contains(where: { ArtboardCommands.asciiLower($0.name) == ArtboardCommands.asciiLower(name) }) {
            throw EngineError.bad(cmd, "A preset named \"\(name)\" already exists; choose another name")
        }
        if st.documents.count >= maxPresets { throw EngineError.bad(cmd, "At most \(maxPresets) document presets can be saved") }
        let settings = try Settings.fromParams(s, p["settings"] ?? .null, cmd)
        let preset = Preset(name: name, settings: settings)
        s.state[Key.self].documents.append(preset)
        changed(s)
        return ["preset": preset.json]
    }

    static func find(_ s: Session, _ name: String) -> Int? {
        let want = ArtboardCommands.asciiLower(name)
        return s.state[Key.self].documents.firstIndex { ArtboardCommands.asciiLower($0.name) == want }
    }

    static func get(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "document.presets.get"
        let name = try reqStr(p, "name", cmd)
        guard let i = find(s, name) else { throw EngineError.bad(cmd, "No such document preset") }
        let preset = s.state[Key.self].documents[i]
        return ["preset": preset.json, "params": preset.settings.commandParams]
    }

    static func delete(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "document.presets.delete"
        let name = try reqStr(p, "name", cmd)
        guard let i = find(s, name) else { throw EngineError.bad(cmd, "No such document preset") }
        s.state[Key.self].documents.remove(at: i)
        changed(s)
        return ["deleted": .string(name)]
    }

    static func register(into r: inout CommandRegistry) {
        r.add([
            CommandSpec("document.presets.list", "List Document Presets", params: "{}", module: m, journal: false) { s, _ in
                ["presets": .array(s.state[Key.self].documents.map(\.json))]
            },
            CommandSpec("document.presets.get", "Get Document Preset",
                        params: #"{"name":str} -> {preset,params} (params for file.new; no document is created)"#,
                        module: m, journal: false) { s, p in try get(s, p) },
            CommandSpec("document.presets.save", "Save Document Preset",
                        params: ##"{"name":str (trimmed, ASCII case-insensitive unique, 1..255 characters),"settings":{"width":px,"height":px,"resolution":ppi=72,"mode":"rgb|gray|cmyk|lab"="rgb","depth":8|16|32=8,"background":"white|black|transparent|backgroundColor|#rrggbb"="white","backgroundColor":[r,g,b]?,"unit":"px|in|cm|mm|pt|pica"="px","resolutionUnit":"in|cm"="in"}}"##,
                        module: m) { s, p in try save(s, p) },
            CommandSpec("document.presets.delete", "Delete Document Preset", params: #"{"name":str}"#, module: m) { s, p in try delete(s, p) },
            CommandSpec("document.recent.list", "List Recent Document Settings",
                        params: "{} -> {recent:[settings]} (newest first; each settings.command params minus unit/resolutionUnit go to file.new)",
                        module: m, journal: false) { s, _ in
                ["recent": .array(s.state[Key.self].recent.map(\.json))]
            },
            // Bookkeeping for File › New, not an editing step an action should replay.
            CommandSpec("document.recent.add", "Add Recent Document Settings",
                        params: #"{"settings":{same fields as document.presets.save}} (File › New records each document it creates; newest first, max 20, duplicates collapsed)"#,
                        module: m, journal: false) { s, p in try addRecent(s, p) },
        ])
    }
}
