// Port of photocraft-cms (crates/cms/src/lutfile.rs: `LutFile`, `parse`, `parse_cube`, `parse_3dl`, `parse_look`, `BUILTIN`, `builtin`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Part of the adjust_cmds port (Color Lookup's tables): creative 3D LUT files and the generated
// built-in looks. The parser is the same port PCIO's `AdjustMap.LutFile` carries (the engine can't
// depend on PCIO), plus the built-ins photocraft ships.
//
// Every table is normalised to `LutFile`: `size`³ RGB triplets in 0...1, **red varying fastest**
// (`((b·size + g)·size + r)·3`). Formats follow their public descriptions: the Adobe "Cube LUT
// Specification 1.0", the Lustre 3DL layout as documented by OpenColorIO, and the SpeedGrade `.look`
// XML (hex-encoded little-endian float32 RGB triplets).

import Foundation

extension AdjustCommands {
    /// A LUT file could not be read (photocraft `LutError`); `message` is photocraft's text.
    struct LutError: Error, Equatable, CustomStringConvertible {
        var message: String
        init(_ message: String) { self.message = message }
        var description: String { message }
    }

    /// A parsed 3D LUT.
    struct LutFile: Equatable {
        var title: String
        var size: Int
        /// `size`³ × 3 values, red fastest.
        var data: [Float]
        /// The input domain the table expects (`.cube` `DOMAIN_MIN`/`DOMAIN_MAX`,
        /// `LUT_3D_INPUT_RANGE`). `[0, 1]` is the identity default.
        var domainMin: SIMD3<Float> = .zero
        var domainMax: SIMD3<Float> = .one

        /// Largest edge length accepted (64³ is Photoshop's practical maximum; 129 leaves headroom
        /// while keeping the GPU table within texture limits).
        static let maxSize = 129

        /// The identity table of edge `size`.
        static func identity(_ size: Int) -> LutFile { fromFn("Identity", size) { $0 } }

        /// Samples `f` on a `size`³ grid (outputs clamped to 0...1).
        static func fromFn(_ title: String, _ size: Int, _ f: (SIMD3<Float>) -> SIMD3<Float>) -> LutFile {
            let m = Float(max(size, 2) - 1)
            var data: [Float] = []
            let n = max(size, 0)
            data.reserveCapacity(n * n * n * 3)
            for b in 0 ..< n {
                for g in 0 ..< n {
                    for r in 0 ..< n {
                        let o = f(SIMD3(Float(r) / m, Float(g) / m, Float(b) / m))
                        data += [clampLut(o.x), clampLut(o.y), clampLut(o.z)]
                    }
                }
            }
            return LutFile(title: title, size: size, data: data)
        }

        /// Whether the table expects plain 0...1 inputs.
        var domainIsDefault: Bool { domainMin == .zero && domainMax == .one }

        fileprivate func check() -> Result<LutFile, LutError> {
            switch checkedDataLen(size) {
            case let .failure(e): return .failure(e)
            case let .success((entries, dataLen)):
                if data.count != dataLen { return .failure(LutError("expected \(entries) entries, found \(data.count / 3)")) }
                if data.contains(where: { !$0.isFinite }) { return .failure(LutError("non-finite LUT value")) }
                return .success(self)
            }
        }

        // MARK: Parsing

        /// Parses a LUT, picking the format from `fileName`'s extension (falls back to sniffing).
        static func parse(_ fileName: String, _ bytes: [UInt8]) -> Result<LutFile, LutError> {
            let lower = fileName.lowercased()
            let text = String(decoding: bytes, as: UTF8.self)
            if lower.hasSuffix(".3dl") { return parse3dl(text) }
            if lower.hasSuffix(".look") || trimStart(Array(text.unicodeScalars)).first == "<" { return parseLook(text) }
            return parseCube(text)
        }

        /// Adobe / Resolve `.cube`. 1D LUTs (`LUT_1D_SIZE`) are expanded to a 33³ table.
        static func parseCube(_ text: String) -> Result<LutFile, LutError> {
            var title = ""
            var size3 = 0, size1 = 0
            var dmin = SIMD3<Float>(repeating: 0), dmax = SIMD3<Float>(repeating: 1)
            var rows: [Float] = []
            for raw in lines(text) {
                let line = trim(beforeHash(raw))
                if line.isEmpty { continue }
                let lineText = string(line)
                var it = splitWhitespace(line)[...]
                let key = it.popFirst() ?? ""
                func nums() -> Result<SIMD3<Float>, LutError> {
                    let v = it.compactMap(parseF32)
                    return v.count == 3 ? .success(SIMD3(v[0], v[1], v[2])) : .failure(LutError("bad line `\(lineText)`"))
                }
                switch key {
                case "TITLE":
                    title = string(trimMatching(trim(Array(line.dropFirst(5))), "\""))
                case "LUT_3D_SIZE":
                    guard let s = it.first.flatMap(parseUsize) else { return .failure(LutError("bad LUT_3D_SIZE")) }
                    size3 = s
                case "LUT_1D_SIZE":
                    guard let s = it.first.flatMap(parseUsize) else { return .failure(LutError("bad LUT_1D_SIZE")) }
                    size1 = s
                case "DOMAIN_MIN":
                    switch nums() {
                    case let .success(v): dmin = v
                    case let .failure(e): return .failure(e)
                    }
                case "DOMAIN_MAX":
                    switch nums() {
                    case let .success(v): dmax = v
                    case let .failure(e): return .failure(e)
                    }
                case "LUT_3D_INPUT_RANGE", "LUT_1D_INPUT_RANGE":
                    let v = it.compactMap(parseF32)
                    if v.count == 2 {
                        dmin = SIMD3(repeating: v[0])
                        dmax = SIMD3(repeating: v[1])
                    }
                default:
                    guard let c = key.unicodeScalars.first, ("0" ... "9").contains(c) || c == "-" || c == "+" || c == "." else {
                        // Unknown keywords (e.g. Resolve's LUT_IN_VIDEO_RANGE) are ignored, as the spec allows.
                        continue
                    }
                    guard let first = parseF32(key) else { return .failure(LutError("bad number in `\(lineText)`")) }
                    let v = [first] + it.compactMap(parseF32)
                    if v.count != 3 { return .failure(LutError("bad data line `\(lineText)`")) }
                    rows += v
                }
            }
            let domainOK = (0 ..< 3).allSatisfy { dmin[$0] < dmax[$0] && dmin[$0].isFinite && dmax[$0].isFinite }
            if size3 > 0 || size1 >= 2, !domainOK {
                return .failure(LutError("DOMAIN_MIN \(debugArray(dmin)) must lie below DOMAIN_MAX \(debugArray(dmax))"))
            }
            if size3 > 0 {
                return LutFile(title: title, size: size3, data: rows, domainMin: dmin, domainMax: dmax).check()
            }
            if size1 >= 2 {
                let (expected, o) = size1.multipliedReportingOverflow(by: 3)
                if o { return .failure(LutError("unsupported 1D LUT size \(size1)")) }
                if rows.count != expected { return .failure(LutError("no LUT_3D_SIZE in .cube file")) }
                // The 1D table is resampled onto a 0...1 cube, so its input domain is baked into the
                // resample: an input `v` reads the table at `(v - min) / (max - min)`, saturating outside.
                func curve(_ ch: Int, _ v: Float) -> Float {
                    let t = (v - dmin[ch]) / (dmax[ch] - dmin[ch])
                    let x = (t.isFinite ? clampLut(t) : 0) * Float(size1 - 1)
                    let i = min(satCastInt(x.rounded(.down)), size1 - 2)
                    let f = x - Float(i)
                    return rows[i * 3 + ch] * (1 - f) + rows[(i + 1) * 3 + ch] * f
                }
                var l = fromFn(title, 33) { c in SIMD3(curve(0, c.x), curve(1, c.y), curve(2, c.z)) }
                l.title = title
                return l.check()
            }
            return .failure(LutError("no LUT_3D_SIZE in .cube file"))
        }

        /// Lustre `.3dl`: an optional shaper line of input values, then integer RGB rows with **blue**
        /// varying fastest; the output bit depth is inferred from the largest value.
        static func parse3dl(_ text: String) -> Result<LutFile, LutError> {
            var rows: [SIMD3<Double>] = []
            for raw in lines(text) {
                let line = trim(beforeHash(raw))
                if line.isEmpty || (line.first.map { $0.isASCII && $0.properties.isAlphabetic } ?? false) { continue }
                let v = splitWhitespace(line).compactMap(parseF64)
                if v.count == 3 { rows.append(SIMD3(v[0], v[1], v[2])) }
                // Lines with more than three numbers are the input shaper; it is assumed linear.
            }
            let n = satCastInt(cbrt(Double(rows.count)).rounded())
            if n < 2 || n * n * n != rows.count { return .failure(LutError("\(rows.count) rows is not a cube")) }
            let mx = rows.reduce(0.0) { acc, r in rustMax(rustMax(rustMax(acc, r.x), r.y), r.z) }
            let scale: Double = mx <= 1 ? 1 : ([1023.0, 4095.0, 16383.0, 65535.0].first { mx <= $0 } ?? mx)
            var data = [Float](repeating: 0, count: n * n * n * 3)
            for (i, row) in rows.enumerated() {
                let (r, g, b) = (i / (n * n), (i / n) % n, i % n)
                let at = ((b * n + g) * n + r) * 3
                for k in 0 ..< 3 { data[at + k] = Float(row[k] / scale) }
            }
            return LutFile(title: "", size: n, data: data).check()
        }

        /// SpeedGrade `.look`: `<size>` and a hex `<data>` string of little-endian float32 RGB triplets
        /// (red fastest).
        static func parseLook(_ text: String) -> Result<LutFile, LutError> {
            let bytes = Array(text.utf8)
            func tag(_ name: String) -> String? {
                let open = Array("<\(name)>".utf8), close = Array("</\(name)>".utf8)
                guard let o = find(bytes, open, from: 0) else { return nil }
                let start = o + open.count
                guard let end = find(bytes, close, from: start) else { return nil }
                let inner = Array(String(decoding: bytes[start ..< end], as: UTF8.self).unicodeScalars)
                return string(trim(trimMatching(trim(inner), "\"")))
            }
            guard let size = tag("size").flatMap(parseUsize) else { return .failure(LutError("no <size> in .look")) }
            let entries: Int
            switch checkedDataLen(size) {
            case let .failure(e): return .failure(e)
            case let .success((e, _)): entries = e
            }
            guard let hexText = tag("data") else { return .failure(LutError("no <data> in .look")) }
            let hex = hexText.utf8.filter { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x46) || ($0 >= 0x61 && $0 <= 0x66) }
            func nib(_ c: UInt8) -> UInt8 {
                switch c {
                case 0x30 ... 0x39: c - 0x30
                case 0x41 ... 0x46: c - 0x41 + 10
                case 0x61 ... 0x66: c - 0x61 + 10
                default: 0
                }
            }
            var raw: [UInt8] = []
            raw.reserveCapacity(hex.count / 2)
            var i = 0
            while i + 1 < hex.count {
                raw.append(nib(hex[i]) << 4 | nib(hex[i + 1]))
                i += 2
            }
            var floats: [Float] = []
            floats.reserveCapacity(raw.count / 4)
            var j = 0
            while j + 3 < raw.count {
                let bits = UInt32(raw[j]) | UInt32(raw[j + 1]) << 8 | UInt32(raw[j + 2]) << 16 | UInt32(raw[j + 3]) << 24
                floats.append(Float(bitPattern: bits))
                j += 4
            }
            let (rgba, o) = entries.multipliedReportingOverflow(by: 4)
            if o { return .failure(LutError("unsupported LUT size \(size)")) }
            var data = floats
            if floats.count == rgba {
                data = []
                data.reserveCapacity(entries * 3)
                var k = 0
                while k + 3 < floats.count {
                    data += [floats[k], floats[k + 1], floats[k + 2]]
                    k += 4
                }
            }
            return LutFile(title: tag("title") ?? "", size: size, data: data).check()
        }
    }
}

// MARK: - Helpers (Rust string and number semantics)

private func clampLut(_ v: Float) -> Float {
    var x = v
    if x < 0 { x = 0 }
    if x > 1 { x = 1 }
    return x
}

/// Rust `f64::max` (NaN operands are ignored).
private func rustMax(_ a: Double, _ b: Double) -> Double {
    if a.isNaN { return b }
    if b.isNaN { return a }
    return Swift.max(a, b)
}

/// Rust's saturating `x as usize` for a non-negative value.
private func satCastInt(_ x: Float) -> Int { satCastInt(Double(x)) }

private func satCastInt(_ x: Double) -> Int {
    if x.isNaN || x <= 0 { return 0 }
    if x >= Double(Int.max) { return Int.max }
    return Int(x)
}

private func checkedDataLen(_ size: Int) -> Result<(Int, Int), AdjustCommands.LutError> {
    guard (2 ... AdjustCommands.LutFile.maxSize).contains(size) else { return .failure(AdjustCommands.LutError("unsupported LUT size \(size)")) }
    return .success((size * size * size, size * size * size * 3))
}

/// Rust `str::lines`: split on `\n`, dropping one trailing `\r` from each line.
private func lines(_ text: String) -> [[Unicode.Scalar]] {
    var out: [[Unicode.Scalar]] = []
    var cur: [Unicode.Scalar] = []
    for s in text.unicodeScalars {
        if s == "\n" {
            if cur.last == "\r" { cur.removeLast() }
            out.append(cur)
            cur = []
        } else {
            cur.append(s)
        }
    }
    if !cur.isEmpty {
        if cur.last == "\r" { cur.removeLast() }
        out.append(cur)
    }
    return out
}

private func beforeHash(_ line: [Unicode.Scalar]) -> [Unicode.Scalar] {
    if let i = line.firstIndex(of: "#") { return Array(line[..<i]) }
    return line
}

private func isWS(_ s: Unicode.Scalar) -> Bool { s.properties.isWhitespace }

private func trimStart(_ s: [Unicode.Scalar]) -> [Unicode.Scalar] { Array(s.drop(while: isWS)) }

private func trim(_ s: [Unicode.Scalar]) -> [Unicode.Scalar] {
    var t = trimStart(s)
    while let l = t.last, isWS(l) { t.removeLast() }
    return t
}

private func trimMatching(_ s: [Unicode.Scalar], _ c: Unicode.Scalar) -> [Unicode.Scalar] {
    var t = Array(s.drop { $0 == c })
    while t.last == c { t.removeLast() }
    return t
}

private func splitWhitespace(_ s: [Unicode.Scalar]) -> [String] {
    s.split(whereSeparator: isWS).map { string(Array($0)) }
}

private func string(_ s: [Unicode.Scalar]) -> String {
    var v = String.UnicodeScalarView()
    v.append(contentsOf: s)
    return String(v)
}

private func find(_ hay: [UInt8], _ needle: [UInt8], from: Int) -> Int? {
    guard !needle.isEmpty, hay.count >= needle.count, from <= hay.count - needle.count else { return nil }
    var i = from
    while i <= hay.count - needle.count {
        if hay[i] == needle[0], Array(hay[i ..< i + needle.count]) == needle { return i }
        i += 1
    }
    return nil
}

/// Rust `str::parse::<f32>()`: decimal (or `inf`/`infinity`/`nan`), no hex forms.
private func parseF32(_ s: String) -> Float? { rustFloatSyntax(s) ? Float(s) : nil }

private func parseF64(_ s: String) -> Double? { rustFloatSyntax(s) ? Double(s) : nil }

private func rustFloatSyntax(_ s: String) -> Bool {
    var b = Array(s.utf8)
    if let f = b.first, f == UInt8(ascii: "+") || f == UInt8(ascii: "-") { b.removeFirst() }
    let word = String(decoding: b, as: UTF8.self).lowercased()
    if ["inf", "infinity", "nan"].contains(word) { return true }
    var digits = false, i = 0
    while i < b.count, b[i] >= 0x30, b[i] <= 0x39 { digits = true; i += 1 }
    if i < b.count, b[i] == UInt8(ascii: ".") {
        i += 1
        while i < b.count, b[i] >= 0x30, b[i] <= 0x39 { digits = true; i += 1 }
    }
    guard digits else { return false }
    if i < b.count, b[i] == UInt8(ascii: "e") || b[i] == UInt8(ascii: "E") {
        i += 1
        if i < b.count, b[i] == UInt8(ascii: "+") || b[i] == UInt8(ascii: "-") { i += 1 }
        var exp = false
        while i < b.count, b[i] >= 0x30, b[i] <= 0x39 { exp = true; i += 1 }
        guard exp else { return false }
    }
    return i == b.count
}

/// Rust `str::parse::<usize>()` (optional `+`, decimal digits only). Values past `Int.max` saturate
/// (every caller rejects them as a size anyway).
private func parseUsize(_ s: String) -> Int? {
    var b = Array(s.utf8)
    if b.first == UInt8(ascii: "+") { b.removeFirst() }
    guard !b.isEmpty, b.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return nil }
    return Int(String(decoding: b, as: UTF8.self)) ?? Int.max
}

/// `format!("{:?}", [f32; 3])` (shortest round-trip floats, `1.0` style).
private func debugArray(_ v: SIMD3<Float>) -> String {
    func one(_ x: Float) -> String {
        if x.isNaN { return "NaN" }
        if x.isInfinite { return x < 0 ? "-inf" : "inf" }
        var s = "\(x)"
        if let e = s.firstIndex(where: { $0 == "e" }) {
            var mant = String(s[..<e]), exp = String(s[s.index(after: e)...])
            if exp.hasPrefix("+") { exp.removeFirst() }
            let neg = exp.hasPrefix("-")
            if neg { exp.removeFirst() }
            while exp.count > 1, exp.hasPrefix("0") { exp.removeFirst() }
            if mant.hasSuffix(".0") { mant.removeLast(2) }
            s = mant + "e" + (neg ? "-" : "") + exp
        }
        return s
    }
    return "[\(one(v.x)), \(one(v.y)), \(one(v.z))]"
}

extension AdjustCommands.LutFile {
    /// `DOMAIN_MIN` / `DOMAIN_MAX` as Rust's `{:?}` prints them (error messages).
    var domainDescription: (String, String) { (debugArray(domainMin), debugArray(domainMax)) }

    /// Generated looks shipped with Photocraft (procedural, CC0): `(id, label)`.
    static let builtinLooks: [(id: String, label: String)] = [
        ("warm", "Warm Filter"),
        ("cool", "Cool Filter"),
        ("tealOrange", "Teal & Orange"),
        ("bleachBypass", "Bleach Bypass"),
        ("fadedFilm", "Faded Film"),
        ("dayForNight", "Day for Night"),
        ("monoContrast", "Mono High Contrast"),
        ("crossProcess", "Cross Process"),
    ]

    /// A built-in look by id (33³), or nil.
    static func builtin(_ id: String) -> AdjustCommands.LutFile? {
        guard let label = builtinLooks.first(where: { $0.id == id })?.label else { return nil }
        func luma(_ c: SIMD3<Float>) -> Float { 0.299 * c.x + 0.587 * c.y + 0.114 * c.z }
        func smooth(_ x0: Float) -> Float {
            let x = Swift.min(Swift.max(x0, 0), 1)
            return x * x * (3 - 2 * x)
        }
        let f: (SIMD3<Float>) -> SIMD3<Float>
        switch id {
        case "warm": f = { c in SIMD3(c.x * 0.92 + 0.08, c.y * 0.97 + 0.02, c.z * 0.85) }
        case "cool": f = { c in SIMD3(c.x * 0.86, c.y * 0.97 + 0.01, c.z * 0.9 + 0.1) }
        case "tealOrange":
            f = { c in
                // Shadows toward teal, highlights toward orange, skin-ish midtones kept.
                let l = luma(c)
                let t = smooth(l)
                let teal = SIMD3<Float>(0, 0.5, 0.55)
                let orange = SIMD3<Float>(1, 0.62, 0.3)
                var o = SIMD3<Float>()
                for k in 0..<3 {
                    let tint = teal[k] * (1 - t) + orange[k] * t
                    o[k] = c[k] * 0.75 + Swift.min(tint * l * 1.1, 1) * 0.25 + (smooth(c[k]) - c[k]) * 0.3
                }
                return o
            }
        case "bleachBypass":
            f = { c in
                let l = luma(c)
                let s = smooth(l)
                var o = SIMD3<Float>()
                for k in 0..<3 {
                    let desat = c[k] * 0.45 + l * 0.55
                    o[k] = desat * 0.5 + s * 0.5
                }
                return o
            }
        case "fadedFilm":
            f = { c in
                let l = luma(c)
                let tint = SIMD3<Float>(1, 0.96, 0.88)
                var o = SIMD3<Float>()
                for k in 0..<3 { o[k] = (0.08 + (c[k] * 0.8 + l * 0.2) * 0.84) * tint[k] + 0.02 }
                return o
            }
        case "dayForNight":
            f = { c in
                let l = luma(c)
                return SIMD3(l * 0.35, l * 0.45 + c.y * 0.05, l * 0.65 + c.z * 0.15)
            }
        case "monoContrast": f = { c in SIMD3(repeating: smooth(smooth(luma(c)))) }
        default: f = { c in SIMD3(smooth(c.x) * 1.05, c.y * 1.1 - 0.03, c.z * 0.7 + 0.15) } // crossProcess
        }
        return fromFn(label, 33, f)
    }
}
