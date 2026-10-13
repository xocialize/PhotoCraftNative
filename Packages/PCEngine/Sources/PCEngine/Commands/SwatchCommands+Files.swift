// Port of photocraft-engine (crates/engine/src/swatch_cmds.rs: `Format`, `read_file`, `write_file`, `import`, `export`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Swatches panel › Import Swatches… / Export Swatches…: Photoshop `.aco` and Adobe Swatch Exchange
// `.ase` files, parsed and written by PCPSD (`PSDAco`, `PSDAse`; photocraft-psd `aco`/`ase`).
// `.aco` keeps 16-bit values and colour-book entries verbatim; `.ase` keeps groups, float values
// and the process/global/spot kind.

import Foundation
import PCDocument
import PCPaint
import PCPSD

extension SwatchCommands {
    /// File format of a swatch file.
    enum FileFormat: String {
        case aco, ase

        static func parse(_ s: String) -> FileFormat? {
            var t = Substring(s)
            while t.hasPrefix(".") { t = t.dropFirst() }
            return FileFormat(rawValue: t.lowercased())
        }
    }

    static func extFormat(_ path: String?) -> FileFormat? {
        guard let path, let ext = EngineIO.fileExtension(path) else { return nil }
        return FileFormat.parse(ext)
    }

    static func q16(_ v: Float) -> UInt16 { UInt16((unit(v) * 65535).rounded()) }

    static func fromAco(_ c: PSDAco.Color) -> SwatchColor {
        func f(_ v: UInt16) -> Float { Float(v) / 65535 }
        switch c {
        case let .rgb(r, g, b): return .rgb(SIMD3(f(r), f(g), f(b)))
        case let .hsb(h, s, b): return .hsb(SIMD3(f(h) * 360, f(s), f(b)))
        case let .cmyk(c, m, y, k): return .cmyk(SIMD4(f(c), f(m), f(y), f(k)))
        case let .lab(l, a, b): return .lab(SIMD3(Float(min(l, 10000)) / 100, Float(a) / 100, Float(b) / 100))
        case let .gray(g): return .gray(1 - Float(min(g, 10000)) / 10000)
        case let .other(space, values): return .book(space: space, values: values)
        }
    }

    static func toAco(_ c: SwatchColor) -> PSDAco.Color {
        switch c {
        case .rgb(let v): return .rgb(q16(v.x), q16(v.y), q16(v.z))
        case .hsb(let v):
            let h = v.x.isFinite ? remEuclid(v.x, 360) : 0
            return .hsb(UInt16(min((h / 360 * 65535).rounded(), 65535)), q16(v.y), q16(v.z))
        case .cmyk(let v): return .cmyk(q16(v.x), q16(v.y), q16(v.z), q16(v.w))
        case .lab(let v):
            func ab(_ x: Float) -> Int16 { x.isFinite ? Int16(min(max((x * 100).rounded(), -12800), 12700)) : 0 }
            let l = v.x.isFinite ? v.x : 0
            return .lab(l: UInt16(min(max((l * 100).rounded(), 0), 10000)), a: ab(v.y), b: ab(v.z))
        case .gray(let k): return .gray(UInt16(((1 - unit(k)) * 10000).rounded()))
        case let .book(space, values): return .other(space: space, values: values)
        }
    }

    static func fromAse(_ c: PSDAse.Color) -> SwatchColor? {
        switch c {
        case let .rgb(r, g, b): return .rgb(SIMD3(r, g, b))
        case let .cmyk(c, m, y, k): return .cmyk(SIMD4(c, m, y, k))
        // L is stored as a fraction (L*/100); a few writers store L* itself, which can only be
        // told apart above 1.
        case let .lab(l, a, b): return .lab(SIMD3(l > 1 ? l : l * 100, a, b))
        case let .gray(g): return .gray(1 - g)
        case .other: return nil
        }
    }

    static func toAse(_ c: SwatchColor) -> PSDAse.Color? {
        switch c {
        case .rgb(let v): return .rgb(v.x, v.y, v.z)
        // ASE has no HSB; HSB is a view of RGB, so this is exact up to float rounding.
        case .hsb(let v):
            let r = hsbToRGB(v)
            return .rgb(r.x, r.y, r.z)
        case .cmyk(let v): return .cmyk(v.x, v.y, v.z, v.w)
        case .lab(let v): return .lab(v.x / 100, v.y, v.z)
        case .gray(let k): return .gray(1 - k)
        case .book: return nil
        }
    }

    static func kindFromAse(_ k: PSDAse.Kind) -> SwatchKind {
        switch k {
        case .global: .global
        case .spot: .spot
        case .process: .process
        }
    }

    static func kindToAse(_ k: SwatchKind) -> PSDAse.Kind {
        switch k {
        case .global: .global
        case .spot: .spot
        case .process: .process
        }
    }

    struct FileError: Error, CustomStringConvertible {
        var description: String
    }

    /// Parses a swatch file into groups (`group` names the group for ungrouped colours)
    /// (photocraft `read_file`).
    static func readFile(_ bytes: [UInt8], _ format: FileFormat, _ group: String) throws(FileError) -> ([Group], [String]) {
        var warnings: [String] = []
        var out: [Group] = []
        func fallback(_ i: Int, _ name: String) -> String {
            let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? "Swatch \(i + 1)" : clip(t)
        }
        switch format {
        case .aco:
            let f: PSDAco.File
            do { f = try PSDAco.parse(Data(bytes)) } catch { throw FileError(description: "not a readable .aco swatch file: \(error)") }
            let books = f.swatches.filter { if case .other = $0.color { true } else { false } }.count
            if books > 0 {
                warnings.append("\(books) swatches use a colour book or colour space PhotoCraft can't show; they are kept (shown gray) and saved back unchanged")
            }
            let items = f.swatches.enumerated().map { Swatch(name: fallback($0.offset, $0.element.name), color: fromAco($0.element.color), kind: .process) }
            out.append(Group(name: group, items: items))
        case .ase:
            let f: PSDAse.File
            do { f = try PSDAse.parse(Data(bytes)) } catch { throw FileError(description: "not a readable .ase swatch file: \(error)") }
            var skipped = 0
            var n = 0
            func conv(_ s: PSDAse.Swatch) -> Swatch? {
                n += 1
                guard let color = fromAse(s.color) else {
                    skipped += 1
                    return nil
                }
                return Swatch(name: fallback(n - 1, s.name), color: color, kind: kindFromAse(s.kind))
            }
            var loose: [Swatch] = []
            for e in f.entries {
                switch e {
                case .swatch(let s):
                    if let sw = conv(s) { loose.append(sw) }
                case let .group(name, swatches):
                    let items = swatches.compactMap(conv)
                    let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    out.append(Group(name: t.isEmpty ? group : clip(t), items: items))
                }
            }
            if !loose.isEmpty || out.isEmpty { out.insert(Group(name: group, items: loose), at: 0) }
            if skipped > 0 { warnings.append("\(skipped) swatches in an unknown colour model were skipped") }
        }
        if total(out) == 0 { throw FileError(description: "the file holds no swatches") }
        return (out, warnings)
    }

    /// Encodes groups as a swatch file; returns the bytes, the number of swatches written and
    /// warnings about what the format cannot hold (photocraft `write_file`).
    static func writeFile(_ groups: [Group], _ format: FileFormat) throws(FileError) -> ([UInt8], Int, [String]) {
        var warnings: [String] = []
        switch format {
        case .aco:
            let swatches = groups.flatMap(\.items).map { PSDAco.Swatch(name: $0.name, color: toAco($0.color)) }
            if groups.count > 1 { warnings.append(".aco files have no groups; the swatches were saved as one list") }
            if groups.flatMap(\.items).contains(where: { $0.kind != .process }) {
                warnings.append(".aco files don't mark spot or global colours; save as .ase to keep them")
            }
            do { return ([UInt8](try PSDAco.write(swatches)), swatches.count, warnings) } catch { throw FileError(description: "\(error)") }
        case .ase:
            var books = 0
            var entries: [PSDAse.Entry] = []
            var n = 0
            for g in groups {
                let swatches: [PSDAse.Swatch] = g.items.compactMap { s in
                    guard let color = toAse(s.color) else {
                        books += 1
                        return nil
                    }
                    return PSDAse.Swatch(name: s.name, color: color, kind: kindToAse(s.kind))
                }
                n += swatches.count
                entries.append(.group(name: g.name, swatches: swatches))
            }
            if books > 0 {
                warnings.append("\(books) colour-book swatches can't be stored in an .ase file and were left out (save as .aco to keep them)")
            }
            do { return ([UInt8](try PSDAse.write(PSDAse.File(entries: entries))), n, warnings) } catch { throw FileError(description: "\(error)") }
        }
    }

    static let aseSignature: [UInt8] = Array("ASEF".utf8)

    static func importFile(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "swatches.import"
        let (bytes, stem) = try PresetImportCommands.fileBytes(s.services.fileSystem, p, cmd, ".aco or .ase file")
        let format: FileFormat
        if let f = strParam(p, "format") {
            guard let v = FileFormat.parse(f) else { throw EngineError.bad(cmd, "unknown format `\(f)` (aco|ase)") }
            format = v
        } else if bytes.starts(with: aseSignature) {
            format = .ase
        } else if bytes.count >= 2, bytes[0] == 0, bytes[1] == 1 || bytes[1] == 2 {
            format = .aco
        } else {
            guard let v = extFormat(strParam(p, "path")) else { throw EngineError.bad(cmd, "not an .aco or .ase swatch file") }
            format = v
        }
        let mode = strParam(p, "mode") ?? "append"
        let replace: Bool
        switch mode {
        case "append": replace = false
        case "replace": replace = true
        default: throw EngineError.bad(cmd, "unknown mode `\(mode)` (append|replace)")
        }
        let group: String
        if let g = try nameParam(p, "group", cmd) {
            group = g
        } else {
            let t = stem.trimmingCharacters(in: .whitespacesAndNewlines)
            group = t.isEmpty ? "Imported Swatches" : clip(t)
        }
        let groups: [Group], warnings: [String]
        do { (groups, warnings) = try readFile(bytes, format, group) } catch { throw EngineError.bad(cmd, "\(error)") }
        let base: [Group] = replace ? [] : library(s)
        if total(base) + total(groups) > maxSwatches || base.count + groups.count > maxGroups {
            throw EngineError.bad(cmd, "too many swatches: the panel holds at most \(maxSwatches) in \(maxGroups) groups")
        }
        var lib = base
        let count = total(groups)
        var names: [String] = []
        // Names stay unique across the library (agents address swatches by name).
        var next: [String: Int] = [:]
        var taken = Set(lib.flatMap { $0.items.map(\.name) })
        for var g in groups {
            g.name = uniqueGroup(lib, g.name)
            for k in g.items.indices {
                let n0 = g.items[k].name
                if taken.contains(n0) {
                    // Resume numbering per base name, so a file of identical names stays linear.
                    var i = next[n0] ?? 2
                    while taken.contains("\(n0) \(i)") { i += 1 }
                    next[n0] = i + 1
                    g.items[k].name = "\(n0) \(i)"
                }
                taken.insert(g.items[k].name)
            }
            names.append(g.name)
            lib.append(g)
        }
        store(s, lib)
        return ["format": .string(format.rawValue), "mode": .string(mode), "groups": .strings(names), "count": .int(count), "warnings": .strings(warnings)]
    }

    static func exportFile(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "swatches.export"
        let path = strParam(p, "path")
        let format: FileFormat
        if let f = strParam(p, "format") {
            guard let v = FileFormat.parse(f) else { throw EngineError.bad(cmd, "unknown format `\(f)` (aco|ase)") }
            format = v
        } else {
            format = extFormat(path) ?? .aco
        }
        var groups: [Group]
        if let g = try nameParam(p, "group", cmd) {
            groups = [library(s)[try groupOf(s, g, cmd)]]
        } else {
            groups = library(s)
        }
        // Only some swatches (Photoshop: Export Selected Swatches).
        if let a = p["swatches"] {
            guard let list = a.arrayValue else { throw EngineError.bad(cmd, "`swatches` must be a list of names") }
            var want = Set<String>()
            let ix = indexByName(groups, group: nil)
            for v in list {
                guard let name = v.stringValue else { throw EngineError.bad(cmd, "`swatches` names must be strings") }
                if ix[name] == nil { throw EngineError.bad(cmd, "no swatch \"\(name)\"") }
                want.insert(name)
            }
            for i in groups.indices { groups[i].items.removeAll { !want.contains($0.name) } }
            groups.removeAll { $0.items.isEmpty }
        }
        if total(groups) == 0 { throw EngineError.bad(cmd, "no swatches to export") }
        let bytes: [UInt8], count: Int, warnings: [String]
        do { (bytes, count, warnings) = try writeFile(groups, format) } catch { throw EngineError.bad(cmd, "\(error)") }
        var out: [String: JSONValue] = ["format": .string(format.rawValue), "count": .int(count), "bytes": .int(bytes.count), "warnings": .strings(warnings)]
        if let path {
            try FileCommands.writeFile(s, path, bytes)
            out["path"] = .string(path)
        } else {
            out["data"] = .string(Base64.encode(bytes))
        }
        return .object(out)
    }
}
