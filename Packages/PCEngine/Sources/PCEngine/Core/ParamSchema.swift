// Port of photocraft architecture §4.2 (`params: Schema` with UI hints for generated dialogs) over photocraft-engine's params notation (crates/engine/src/commands.rs `CommandSpec::params`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// photocraft documents each command's params in a compact notation written for people and agents:
//
//     {"radius":0.1..1000=1 (px),"mode":"normal|multiply"="normal","layer":id?,"color":"#rrggbb"=foreground}
//
// The notation stays the source of truth (it is what `command.list` shows); this file derives a
// JSON Schema from it for UI generation and MCP tool schemas: ranges become minimum/maximum,
// quoted alternatives become enums, `bool`/`str`/`id`/arrays/objects become types, `=x` becomes
// the default, and everything else (units, notes) the description. Parsing is tolerant: what it
// can't type stays an untyped property with its notation as the description.

import PCDocument

public enum ParamSchema {
    /// The JSON Schema of a params notation.
    public static func schema(_ notation: String) -> JSONValue {
        let (props, rest) = parse(notation)
        var o: [String: JSONValue] = ["type": "object", "additionalProperties": true]
        var p: [String: JSONValue] = [:]
        for prop in props { p[prop.name] = prop.schema }
        o["properties"] = .object(p)
        let desc = rest.trimmingCharacters(in: .whitespaces)
        if !desc.isEmpty { o["description"] = .string(desc) }
        return .object(o)
    }

    struct Property {
        var name: String
        var schema: JSONValue
    }

    /// The properties of the notation's first object and the text around it.
    static func parse(_ s: String) -> ([Property], String) {
        let chars = Array(s)
        guard let open = chars.firstIndex(of: "{"), let close = matching(chars, open) else { return ([], s) }
        let body = String(chars[(open + 1)..<close])
        let rest = String(chars[..<open]) + String(chars[(close + 1)...])
        var props: [Property] = []
        var extra: [String] = []
        for entry in split(body) {
            let e = entry.trimmingCharacters(in: .whitespaces)
            guard e.hasPrefix("\""), let endQuote = e.dropFirst().firstIndex(of: "\""),
                  e[e.index(after: endQuote)...].hasPrefix(":") else {
                if !e.isEmpty { extra.append(e) }
                continue
            }
            let name = String(e[e.index(after: e.startIndex)..<endQuote])
            let spec = String(e[e.index(endQuote, offsetBy: 2)...])
            props.append(Property(name: name, schema: property(spec)))
        }
        return (props, ([rest] + extra).joined(separator: " "))
    }

    /// The schema of one property's notation.
    static func property(_ raw: String) -> JSONValue {
        var spec = raw.trimmingCharacters(in: .whitespaces)
        var notes: [String] = []
        // A trailing parenthetical (or text after a space at depth 0) is a note.
        if let i = topLevelIndex(of: "(", in: spec) {
            notes.append(String(spec[i...]).trimmingCharacters(in: .whitespaces))
            spec = String(spec[..<i]).trimmingCharacters(in: .whitespaces)
        }
        var def: String?
        if let i = topLevelIndex(of: "=", in: spec) {
            def = String(spec[spec.index(after: i)...]).trimmingCharacters(in: .whitespaces)
            spec = String(spec[..<i]).trimmingCharacters(in: .whitespaces)
        }
        var optional = false
        if spec.hasSuffix("?") { optional = true; spec.removeLast() }
        if var d = def, d.hasSuffix("?") { optional = true; d.removeLast(); def = d }
        var o: [String: JSONValue] = [:]
        let t = spec.trimmingCharacters(in: .whitespaces)
        let lower = t.lowercased()
        if t.hasPrefix("\"") {
            let alts = alternatives(t)
            if !alts.isEmpty, alts.allSatisfy(isPlainWord) {
                o["type"] = "string"
                if alts.count > 1 { o["enum"] = .strings(alts) }
            } else {
                o["type"] = "string"
                notes.insert(t, at: 0)
            }
        } else if lower == "bool" || lower == "boolean" {
            o["type"] = "boolean"
        } else if ["str", "string", "text", "name", "path", "file", "dir", "url"].contains(lower) {
            o["type"] = "string"
        } else if let (lo, hi, isInt, unit) = range(t) {
            o["type"] = isInt && (def.map { Double($0).map { $0 == $0.rounded() } ?? true } ?? true) ? "integer" : "number"
            o["minimum"] = .number(lo)
            o["maximum"] = .number(hi)
            if !unit.isEmpty { notes.insert(unit, at: 0) }
        } else if t.contains("|"), t.split(separator: "|").allSatisfy({ Double($0.trimmingCharacters(in: .whitespaces)) != nil }) {
            let nums = t.split(separator: "|").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            o["type"] = nums.allSatisfy { $0 == $0.rounded() } ? "integer" : "number"
            o["enum"] = .doubles(nums)
        } else if ["id", "u32", "u64", "index", "i32", "int", "integer", "usize", "u8", "u16"].contains(lower) {
            o["type"] = "integer"
        } else if ["px", "deg", "number", "f32", "f64", "float", "%", "pt", "ms"].contains(lower) {
            o["type"] = "number"
            if lower != "number" && lower != "f32" && lower != "f64" && lower != "float" { notes.insert(lower, at: 0) }
        } else if t.hasPrefix("[") {
            o["type"] = "array"
            notes.insert(t, at: 0)
        } else if t.hasPrefix("{") || lower == "json" || lower == "object" {
            if t.hasPrefix("{") { o["type"] = "object"; notes.insert(t, at: 0) }
        } else if !t.isEmpty {
            notes.insert(t, at: 0)
        }
        if let d = def, !d.isEmpty {
            if let v = try? JSONValue.parse(d), v.objectValue == nil {
                o["default"] = v
            } else {
                notes.append("default: \(d)")
            }
        }
        if optional { o["x-optional"] = true }
        let desc = notes.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        if !desc.isEmpty { o["description"] = .string(desc) }
        return .object(o)
    }

    static func isPlainWord(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }
    }

    /// `"a|b|c"` or `"a"|"b"` → [a, b, c].
    static func alternatives(_ t: String) -> [String] {
        let stripped = t.replacingOccurrences(of: "\"", with: "")
        return stripped.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// `lo..hi[ unit]`.
    static func range(_ t: String) -> (Double, Double, Bool, String)? {
        guard let r = t.range(of: "..") else { return nil }
        let lo = String(t[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
        var tail = String(t[r.upperBound...]).trimmingCharacters(in: .whitespaces)
        var num = ""
        while let c = tail.first, c.isNumber || c == "." || (c == "-" && num.isEmpty) || c == "e" || c == "+" {
            num.append(c)
            tail.removeFirst()
        }
        guard let a = Double(lo), let b = Double(num) else { return nil }
        let isInt = !lo.contains(".") && !num.contains(".") && !num.contains("e")
        return (a, b, isInt, tail.trimmingCharacters(in: .whitespaces))
    }

    /// Index of the bracket closing `chars[open]`.
    static func matching(_ chars: [Character], _ open: Int) -> Int? {
        var depth = 0, inString = false
        var i = open
        while i < chars.count {
            let c = chars[i]
            if c == "\"" { inString.toggle() } else if !inString {
                if "{[(".contains(c) { depth += 1 }
                if "}])".contains(c) {
                    depth -= 1
                    if depth == 0 { return i }
                }
            }
            i += 1
        }
        return nil
    }

    /// Splits at commas outside quotes and brackets.
    static func split(_ s: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var depth = 0, inString = false
        for c in s {
            if c == "\"" { inString.toggle() }
            if !inString {
                if "{[(".contains(c) { depth += 1 }
                if "}])".contains(c) { depth = max(depth - 1, 0) }
                if c == "," && depth == 0 {
                    out.append(cur)
                    cur = ""
                    continue
                }
            }
            cur.append(c)
        }
        out.append(cur)
        return out
    }

    /// First index of `ch` outside quotes and brackets.
    static func topLevelIndex(of ch: Character, in s: String) -> String.Index? {
        var depth = 0, inString = false
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if c == "\"" { inString.toggle() } else if !inString {
                if c == ch && depth == 0 { return i }
                if "{[(".contains(c) { depth += 1 }
                if "}])".contains(c) { depth = max(depth - 1, 0) }
            }
            i = s.index(after: i)
        }
        return nil
    }
}
