// Port of photocraft-engine (crates/engine/src/preset_import_cmds.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Importing Photoshop preset files.
// - `brush.presets.importAbr` adds the presets of an `.abr` file (v1, v2, v6+) to the brush
//   library as one group named after the file, with the file's own folders nested inside it as
//   Photoshop does (Brushes panel › Import Brushes…, Preset Manager). Parsing is PCPSD's
//   (`PSDAbr`, photocraft-psd `abr`); the mapping onto PCPaint's `BrushSettings` is photocraft-io's
//   `abr_map`, which PCIO does not carry (it would need the brush model), ported here
//   (`PresetImportCommands+Abr.swift`).
// - `gradient.presets.importGrd` adds the gradients of a `.grd` file (version 5) to the Gradients
//   panel as one group (PCPSD's `PSDGrd`).

import Foundation
import PCDocument
import PCPaint
import PCPSD

enum PresetImportCommands: CommandModule {
    static let name = "preset_import_cmds"
    static let m = name

    static func bad(_ cmd: String, _ msg: String) -> EngineError { .bad(cmd, msg) }

    /// Largest accepted file (Photoshop's biggest bundled sets are well under this).
    static let maxFileBytes = 512 << 20

    /// File bytes from `data` (base64) or `path`, plus a default group name (photocraft
    /// `file_bytes`). Files are read through the session's file service.
    static func fileBytes(_ fs: any FileSystemService, _ p: JSONValue, _ cmd: String, _ what: String) throws -> ([UInt8], String) {
        if let d = p["data"] {
            guard let s = d.stringValue else { throw bad(cmd, "`data` must be a base64 string") }
            if s.utf8.count > maxFileBytes / 3 * 4 + 4 { throw bad(cmd, "`data` is too large") }
            guard let bytes = Base64.decode(s) else { throw bad(cmd, "`data` is not valid base64") }
            return (bytes, "")
        }
        guard let path = p["path"]?.stringValue, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw bad(cmd, "give `path` (\(what)) or `data` (base64)")
        }
        // The local file system can say how large the file is before reading it.
        if fs is LocalFileSystem, let n = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber,
           n.uint64Value > UInt64(maxFileBytes) {
            throw bad(cmd, "\(path): file too large (\(n.uint64Value) bytes)")
        }
        let data: Data
        do { data = try fs.read(path) } catch { throw EngineError.other("\(path): \(EngineError.wrap(error))") }
        if data.count > maxFileBytes { throw bad(cmd, "\(path): file too large (\(data.count) bytes)") }
        return ([UInt8](data), FileCommands.stem(path))
    }

    /// A name not used by any preset in `taken` (case-insensitive): `name`, `name 2`, `name 3`…
    static func unique(_ name: String, _ taken: [String]) -> String {
        let lowered = Set(taken.map { $0.lowercased() })
        func free(_ n: String) -> Bool { !lowered.contains(n.lowercased()) }
        if free(name) { return name }
        var i = 2
        while !free("\(name) \(i)") { i += 1 }
        return "\(name) \(i)"
    }

    /// `group`: a non-empty string, else the file's stem, else `fallback`.
    static func groupParam(_ p: JSONValue, _ stem: String, _ fallback: String, _ cmd: String) throws -> String {
        if let v = p["group"] {
            guard let g = v.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !g.isEmpty else {
                throw bad(cmd, "`group` must be a non-empty string")
            }
            return g
        }
        return stem.isEmpty ? fallback : stem
    }

    // MARK: Brushes (.abr)

    static func importAbr(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "brush.presets.importAbr"
        // A background job when started with `Session.start`: reading and decoding run on a
        // worker, cancellable before each brush; the library changes on apply.
        let fs = s.services.fileSystem
        let params = p
        return try s.runJob("Import Brushes", lockDocument: false, work: { ctx -> AbrResult in
            ctx.progress(0, "Importing brushes")
            let (bytes, stem) = try fileBytes(fs, params, cmd, ".abr file")
            let group = try groupParam(params, stem, "Imported Brushes", cmd)
            try ctx.check()
            do {
                let imp = try Abr.read(bytes, group: group, cancelled: { ctx.isCancelled },
                                       progress: { ctx.progress(0.05 + 0.95 * $0, "Importing brushes") })
                return AbrResult(group: group, imp: imp)
            } catch {
                if ctx.isCancelled { throw EngineError.cancelled }
                throw bad(cmd, "\(error)")
            }
        }, apply: { s, r, _ in try addAbrPresets(s, params, r.group, r.imp) })
    }

    struct AbrResult: Sendable {
        var group: String
        var imp: Abr.Import
    }

    static func addAbrPresets(_ s: Session, _ p: JSONValue, _ group: String, _ imp: Abr.Import) throws -> JSONValue {
        // Re-importing a file replaces its group instead of duplicating it.
        if p["replace"]?.boolValue ?? true {
            s.tools.presets.removeAll { !$0.builtin && $0.group == group }
        }
        var taken = s.tools.presets.map(\.name)
        var names: [String] = []
        names.reserveCapacity(imp.presets.count)
        for var preset in imp.presets {
            preset.name = unique(preset.name, taken)
            taken.append(preset.name)
            names.append(preset.name)
            s.tools.presets.append(preset)
        }
        BrushCommands.presetsChanged(s)
        if p["select"]?.boolValue ?? false, let first = names.first, let pr = BrushPresets.find(s.tools.presets, first) {
            let b = pr.brush.pickedOver(s.tools.brush)
            do { try BrushCommands.loadBrushTips(b) } catch { throw bad("brush.presets.importAbr", EngineError.wrap(error).description) }
            s.tools.brush = b
            s.emit(.toolsChanged)
        }
        // Distinct folder paths the file brought (its Photoshop folders, nested inside `group`).
        var folders = Set<[String]>()
        for x in s.tools.presets where !x.builtin && x.group == group {
            for d in 0..<x.folder.count { folders.insert(Array(x.folder[...d])) }
        }
        return ["group": .string(group), "imported": .strings(names), "count": .int(names.count), "folders": .int(folders.count),
                "version": .int(Int(imp.version)), "warnings": .strings(imp.warnings)]
    }

    // MARK: Gradients (.grd)

    static func hsbToRGB(_ c: SIMD3<Float>) -> SIMD3<Float> {
        let h0 = c.x.truncatingRemainder(dividingBy: 360)
        let h = (h0 < 0 ? h0 + 360 : h0) / 60
        let (s, v) = (c.y, c.z)
        let cc = v * s
        let x = cc * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
        let (r, g, b): (Float, Float, Float) = switch h.isFinite ? Int(h) : 0 {
        case 0: (cc, x, 0)
        case 1: (x, cc, 0)
        case 2: (0, cc, x)
        case 3: (0, x, cc)
        case 4: (x, 0, cc)
        default: (cc, 0, x)
        }
        let m = v - cc
        return SIMD3(r + m, g + m, b + m)
    }

    /// CIE Lab (D50, as Photoshop stores it) to sRGB through XYZ with Bradford adaptation to D65.
    static func labToRGB(_ c: SIMD3<Float>) -> SIMD3<Float> {
        let (l, a, b) = (c.x, c.y, c.z)
        let fy = (l + 16) / 116
        let (fx, fz) = (fy + a / 500, fy - b / 200)
        func inv(_ t: Float) -> Float { t > 6.0 / 29.0 ? t * t * t : 3 * (6.0 / 29.0) * (6.0 / 29.0) * (t - 4.0 / 29.0) }
        let (x, y, z) = (0.9642 * inv(fx), inv(fy), 0.8249 * inv(fz))
        // XYZ (D50) → linear sRGB (D65), Bradford-adapted matrix.
        let r = 3.1339 * x - 1.6169 * y - 0.4906 * z
        let g = -0.9788 * x + 1.9161 * y + 0.0335 * z
        let bb = 0.0719 * x - 0.2290 * y + 1.4052 * z
        func gamma(_ c: Float) -> Float {
            let c = min(max(c, 0), 1)
            return c <= 0.003_130_8 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055
        }
        return SIMD3(gamma(r), gamma(g), gamma(bb))
    }

    static func stopColor(_ c: PSDGrd.Color) -> PresetCommands.StopColor {
        func clamp(_ c: SIMD3<Float>) -> PresetCommands.StopColor {
            .rgb(SIMD3(c.x.isFinite ? min(max(c.x, 0), 1) : 0, c.y.isFinite ? min(max(c.y, 0), 1) : 0, c.z.isFinite ? min(max(c.z, 0), 1) : 0))
        }
        switch c {
        case .foreground: return .foreground
        case .background: return .background
        case let .rgb(r, g, b): return clamp(SIMD3(r, g, b))
        case let .hsb(h, s, b): return clamp(hsbToRGB(SIMD3(h, s, b)))
        // Naive (profile-free) ink → RGB, like an uncalibrated preview.
        case let .cmyk(c, m, y, k): return clamp(SIMD3((1 - c) * (1 - k), (1 - m) * (1 - k), (1 - y) * (1 - k)))
        case let .lab(l, a, b): return clamp(labToRGB(SIMD3(l, a, b)))
        case let .gray(g): return clamp(SIMD3(repeating: 1 - g))
        }
    }

    /// `items` sorted by `key`, equal keys keeping their order (Rust's stable `sort_by`).
    static func stableSorted<T>(_ items: [T], by key: (T) -> Float) -> [T] {
        items.enumerated().sorted { a, b in
            let (ka, kb) = (key(a.element), key(b.element))
            if ka.isNaN || kb.isNaN { return (ka.isNaN ? 1 : 0, a.offset) < (kb.isNaN ? 1 : 0, b.offset) }
            return ka != kb ? ka < kb : a.offset < b.offset
        }.map(\.element)
    }

    static func importGrd(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "gradient.presets.importGrd"
        let (bytes, stem) = try fileBytes(s.services.fileSystem, p, cmd, ".grd file")
        let group = try groupParam(p, stem, "Imported Gradients", cmd)
        let grads: [PSDGrd.Gradient]
        do { grads = try PSDGrd.parse(Data(bytes)) } catch { throw bad(cmd, "not a readable gradient file (.grd): \(error)") }
        var warnings: [String] = []
        var items: [PresetCommands.GradientPreset] = []
        var noise = 0
        var midpoints = false
        for (i, g) in grads.enumerated() {
            if g.noise || g.stops.count < 2 {
                noise += 1
                continue
            }
            midpoints = midpoints || g.stops.contains { abs($0.midpoint - 0.5) > 0.01 } || g.opacity.contains { abs($0.midpoint - 0.5) > 0.01 }
            let stops = stableSorted(g.stops.map { PresetCommands.GradientStop($0.location, stopColor($0.color)) }, by: \.location)
            var opacity = stableSorted(g.opacity.map { OpacityStop($0.location, $0.opacity) }, by: \.location)
            if opacity.allSatisfy({ $0.opacity >= 1 }) { opacity.removeAll() }
            let trimmed = g.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = trimmed.isEmpty ? "Gradient \(i + 1)" : trimmed
            items.append(PresetCommands.GradientPreset(name: name, stops: stops, opacity: opacity))
        }
        if noise > 0 { warnings.append("\(noise) noise gradients are not supported and were skipped") }
        if midpoints { warnings.append("colour and opacity midpoints other than 50 % are drawn at 50 %") }
        if items.isEmpty { throw bad(cmd, "the file holds no gradients PhotoCraft can use (noise gradients only)") }
        let names = items.map(\.name)
        if p["replace"]?.boolValue ?? true {
            s.state[PresetCommands.Key.self].gradients.removeAll { $0.name == group }
        }
        s.state[PresetCommands.Key.self].gradients.append(PresetCommands.Group(group, items))
        PresetCommands.presetsChanged(s)
        return ["group": .string(group), "imported": .strings(names), "count": .int(names.count), "warnings": .strings(warnings)]
    }

    // MARK: Specs

    static func register(into r: inout CommandRegistry) {
        r.add([
            CommandSpec("brush.presets.importAbr", "Import Brushes…",
                        params: ##"{"path":".abr file"?,"data":base64 bytes?,"group":string?=file name,"replace":bool=true (replace a group of the same name),"select":bool=false (make the first imported preset current)} → {group, imported, count, folders (nested folders kept from the file), version, warnings}"##,
                        module: m, enabled: Pre.always, run: importAbr),
            CommandSpec("gradient.presets.importGrd", "Import Gradients…",
                        params: ##"{"path":".grd file"?,"data":base64 bytes?,"group":string?=file name,"replace":bool=true (replace a group of the same name)}"##,
                        module: m, enabled: Pre.always, run: importGrd),
        ])
    }
}
