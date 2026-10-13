// Port of photocraft-engine (crates/engine/src/pattern_cmds.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Patterns: Edit › Define Pattern, the pattern library (`pattern.*`), Layer › New Fill Layer ›
// Pattern, and brush textures from library patterns. Two places hold patterns, as in Photoshop:
// - the library (session state, `LibraryKey`): built-in procedural patterns plus defined and
//   imported ones. Library edits are app state, not document history.
// - the document (`Document.patterns`): the patterns its layers use. Commands that apply a pattern
//   copy it into the document in the same history step, so a document always renders on its own.
// Patterns are referenced by `"pattern": id | name` (document first, then library). Pattern ids
// are photocraft's (`Pattern.init(name:surface:width:height:)` hashes the same bytes).
// `.pat` files are read and written by PCIO's `PatternMap` (photocraft-io `pattern_map`).

import Foundation
import PCDocument
import PCFoundation
import PCIOCore
import PCIOMaps
import PCPaint

enum PatternCommands: CommandModule {
    static let name = "pattern_cmds"
    static let m = name
    /// PCDocument's pattern tile (PCPaint, imported here for brush textures, has its own `Pattern`).
    typealias Pattern = PCDocument.Pattern

    /// The app-level pattern library (Window › Patterns), photocraft `Session::patterns`.
    enum LibraryKey: StateKey {
        static let defaultValue: [Pattern] = PatternCommands.builtin()
    }

    static func register(into r: inout CommandRegistry) {
        r.add(specs())
    }

    static func library(_ s: Session) -> [Pattern] { s.state[LibraryKey.self] }

    // MARK: Built-in patterns

    static func hash01(_ x: UInt32, _ y: UInt32, _ seed: UInt32) -> Float {
        var h = (x &* 0x8da6_b343) ^ (y &* 0xd816_3841) ^ (seed &* 0xcb1a_b31f)
        h ^= h >> 13
        h = h &* 0x5bd1_e995
        h ^= h >> 15
        return Float(h & 0xffff) / 65535
    }

    static func procedural(_ name: String, _ w: UInt32, _ h: UInt32, _ f: (UInt32, UInt32) -> SIMD3<Float>) -> Pattern {
        var s = Surface(format: PixelFormat(mode: .rgb, sample: .u8, alpha: false))
        var px: [Float] = []
        px.reserveCapacity(Int(w * h * 3))
        for y in 0..<h {
            for x in 0..<w {
                let c = f(x, y)
                px += [c.x, c.y, c.z]
            }
        }
        // Quantise through the 8-bit surface so ids are stable.
        s.writeRegion(PixelRect(x0: 0, y0: 0, x1: Int32(w), y1: Int32(h)), px)
        return Pattern(name: name, surface: s, width: w, height: h)
    }

    /// Built-in patterns: generated procedurally (photocraft's own, CC0), so the library is never
    /// empty.
    static func builtin() -> [Pattern] {
        func g(_ v: Float) -> SIMD3<Float> { SIMD3(repeating: v) }
        return [
            procedural("Checkerboard", 16, 16) { x, y in g((x / 8 + y / 8) % 2 == 0 ? 0.8 : 1.0) },
            procedural("Diagonal Lines", 8, 8) { x, y in g((x + y) % 8 < 2 ? 0.2 : 1.0) },
            procedural("Dots", 12, 12) { x, y in
                let (dx, dy) = (Float(x) + 0.5 - 6.0, Float(y) + 0.5 - 6.0)
                return g(min(max((dx * dx + dy * dy).squareRoot() - 3.0, 0), 1))
            },
            procedural("Grid", 16, 16) { x, y in g(x == 0 || y == 0 ? 0.55 : 1.0) },
            procedural("Bricks", 32, 16) { x, y in
                let row = y / 8
                let xo = (x + (row % 2 == 1 ? 8 : 0)) % 16
                let mortar = y % 8 == 7 || xo == 15
                let n = hash01(x, y, 7) * 0.08
                return mortar ? SIMD3(0.78 + n, 0.76 + n, 0.72 + n) : SIMD3(0.62 + n, 0.27 + n * 0.5, 0.2)
            },
            procedural("Weave", 16, 16) { x, y in
                let over = ((x / 4) + (y / 4)) % 2 == 0
                let t = over ? Float(y % 4) / 3.0 : Float(x % 4) / 3.0
                let v = 0.55 + 0.35 * (1.0 - abs(2.0 * t - 1.0))
                return SIMD3(v, v * 0.92, v * 0.8)
            },
            procedural("Paper Noise", 64, 64) { x, y in
                // Two octaves of smoothed value noise (wraps at 64 px).
                func oct(_ cell: UInt32, _ seed: UInt32) -> Float {
                    let (cx, cy) = (x / cell, y / cell)
                    let (fx, fy) = (Float(x % cell) / Float(cell), Float(y % cell) / Float(cell))
                    let n = 64 / cell
                    func v(_ i: UInt32, _ j: UInt32) -> Float { hash01(i % n, j % n, seed) }
                    func s(_ t: Float) -> Float { t * t * (3.0 - 2.0 * t) }
                    let (sx, sy) = (s(fx), s(fy))
                    let a = v(cx, cy) + (v(cx + 1, cy) - v(cx, cy)) * sx
                    let b = v(cx, cy + 1) + (v(cx + 1, cy + 1) - v(cx, cy + 1)) * sx
                    return a + (b - a) * sy
                }
                return g(0.78 + 0.14 * oct(8, 1) + 0.08 * oct(2, 2))
            },
        ]
    }

    // MARK: Lookup

    static let hasDoc: CommandEnabled = Pre.hasDoc

    static let hasPattern: CommandEnabled = { s, _ in
        library(s).isEmpty && (s.active?.doc.patterns.isEmpty ?? true) ? "no patterns" : nil
    }

    /// photocraft `resolve`: a pattern by id or name, the active document's first, then the
    /// library. An empty key picks the Patterns panel's selection, else the first library pattern
    /// (Photoshop's default).
    static func resolve(_ s: Session, _ key: String) -> Pattern? {
        if key.isEmpty { return PresetCommands.currentPattern(s) ?? library(s).first }
        if let d = s.active, let p = Pattern.find(d.doc.patterns, id: key, name: key) { return p }
        return Pattern.find(library(s), id: key, name: key)
    }

    static func resolveParam(_ s: Session, _ cmd: String, _ p: JSONValue) throws -> Pattern {
        let key = p["pattern"]?.stringValue ?? ""
        guard let pat = resolve(s, key) else { throw EngineError.bad(cmd, "no pattern \"\(key)\" (see pattern.list)") }
        return pat
    }

    /// Copies `pat` into the document's patterns unless it is already there (by id).
    static func ensureInDoc(_ doc: inout Document, _ pat: Pattern) {
        if !doc.patterns.contains(where: { $0.id == pat.id }) { doc.patterns.append(pat) }
    }

    /// photocraft `resolve_effect`: resolves the pattern of a Pattern Overlay built from params
    /// (its `name` holds the requested key) into a real pattern: the effect with name and id
    /// filled in, plus the pattern to copy into the document.
    static func resolveEffect(_ s: Session, _ fx: Effect) throws -> (Effect, Pattern?) {
        guard case .patternOverlay(var o) = fx else { return (fx, nil) }
        let key = o.id.isEmpty ? o.name : o.id
        guard let pat = resolve(s, key) else {
            throw EngineError.bad("layer.layerStyle.patternOverlay", "no pattern \"\(key)\" (see pattern.list)")
        }
        o.name = pat.name
        o.id = pat.id
        return (.patternOverlay(o), pat)
    }

    static func info(_ p: Pattern, inDocument: Bool, inLibrary: Bool) -> JSONValue {
        let f = p.surface.format
        return [
            "id": .string(p.id), "name": .string(p.displayName), "storedName": .string(p.name), "width": .int(p.width), "height": .int(p.height),
            "mode": .string(f.mode.serdeName), "depth": .string(f.sample.serdeName), "alpha": .bool(f.alpha),
            "inDocument": .bool(inDocument), "inLibrary": .bool(inLibrary),
        ]
    }

    static func list(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let docPats = s.active?.doc.patterns ?? []
        let lib = library(s)
        var out = lib.map { p in info(p, inDocument: docPats.contains { $0.id == p.id }, inLibrary: true) }
        out += docPats.filter { d in !lib.contains { $0.id == d.id } }.map { info($0, inDocument: true, inLibrary: false) }
        return .array(out)
    }

    // MARK: Define Pattern

    /// The visible composite over `r` as a surface in the document's pixel format (with alpha),
    /// placed at the origin.
    static func compositeSurface(_ s: Session, _ doc: Document, _ r: PixelRect) throws -> Surface {
        let buf = try s.services.renderer.render(doc, region: r)
        let df = doc.pixelFormat
        let fmt = PixelFormat(mode: df.mode, sample: df.sample, alpha: true)
        var px: [Float] = []
        px.reserveCapacity(buf.px.count * fmt.channels)
        for q in buf.px { px += fmt.components(fromRGBA: q) }
        var out = Surface(format: fmt)
        out.writeRegion(PixelRect(x0: 0, y0: 0, x1: Int32(r.width), y1: Int32(r.height)), px)
        return out
    }

    /// Rust `Path::file_stem` of a document name.
    static func fileStem(_ name: String) -> String? {
        let comps = name.split(separator: "/", omittingEmptySubsequences: true)
        guard let last = comps.last.map(String.init), last != ".." else { return nil }
        if let dot = last.lastIndex(of: "."), dot != last.startIndex { return String(last[..<dot]) }
        return last
    }

    /// photocraft `default_name`: the name Define Pattern gives a pattern without one: the active
    /// document's name without its extension ("Pattern" without a document), numbered past the
    /// library's existing names.
    static func defaultName(_ s: Session) -> String {
        let docName = s.active?.doc.name ?? ""
        let base = fileStem(docName).flatMap { $0.isEmpty ? nil : $0 } ?? "Pattern"
        let lib = library(s)
        func taken(_ n: String) -> Bool { lib.contains { $0.name == n } }
        if !taken(base) { return base }
        var i = 2
        while taken("\(base) \(i)") { i += 1 }
        return "\(base) \(i)"
    }

    /// `v` rounded and saturated to 32 bits (Rust `f64::round() as i32`).
    static func sat32(_ v: Double) -> Int32 {
        if v.isNaN { return 0 }
        return Int32(min(max(v.rounded(), -2_147_483_648), 2_147_483_647))
    }

    static func define(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "edit.definePattern"
        guard let st = s.active else { throw EngineError.noDocument }
        let doc = st.doc
        var r: PixelRect
        if let a = p["rect"]?.arrayValue, a.count == 4 {
            let v = a.map { sat32($0.doubleValue ?? 0) }
            r = PixelRect(x0: v[0], y0: v[1], x1: v[2], y1: v[3])
        } else {
            r = doc.selection?.contentBounds ?? doc.bounds
        }
        r = r.intersect(doc.bounds)
        if r.isEmpty { throw EngineError.bad(cmd, "the area is empty") }
        if r.width > 4000 || r.height > 4000 { throw EngineError.bad(cmd, "patterns are limited to 4000 × 4000 px") }
        var surf = try compositeSurface(s, doc, r)
        // Opaque patterns drop their alpha channel (as Photoshop does).
        let fmt = surf.format
        let px = surf.readRegion(PixelRect(x0: 0, y0: 0, x1: Int32(r.width), y1: Int32(r.height)))
        let n = fmt.channels
        if stride(from: n - 1, to: px.count, by: n).allSatisfy({ px[$0] >= 1 }) {
            surf = surf.converted(to: fmt.with(alpha: false))
        }
        let name: String
        if let n = p["name"]?.stringValue, !n.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { name = n } else { name = defaultName(s) }
        let pat = Pattern(name: name, surface: surf, width: UInt32(r.width), height: UInt32(r.height))
        let out = info(pat, inDocument: false, inLibrary: true)
        if !library(s).contains(where: { $0.id == pat.id }) { s.state[LibraryKey.self].append(pat) }
        return ["pattern": .string(pat.id), "info": out]
    }

    // MARK: Library edits

    static func libraryIndex(_ s: Session, _ cmd: String, _ p: JSONValue) throws -> Int {
        guard let key = p["pattern"]?.stringValue else { throw EngineError.bad(cmd, "missing `pattern` (id or name)") }
        let lib = library(s)
        guard let found = Pattern.find(lib, id: key, name: key)?.id else { throw EngineError.bad(cmd, "no library pattern \"\(key)\"") }
        return lib.firstIndex { $0.id == found } ?? 0
    }

    static func rename(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "pattern.rename"
        guard let name = p["name"]?.stringValue, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw EngineError.bad(cmd, "missing `name`")
        }
        let i = try libraryIndex(s, cmd, p)
        let id = library(s)[i].id
        s.state[LibraryKey.self][i].name = name
        // A copy stored in the document is renamed too (a document edit, so undoable).
        if s.active?.doc.patterns.contains(where: { $0.id == id }) ?? false {
            try s.edit("Rename Pattern") { doc, _ in
                for k in doc.patterns.indices where doc.patterns[k].id == id { doc.patterns[k].name = name }
            }
        }
        return ["pattern": .string(id), "name": .string(name)]
    }

    static func delete(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let i = try libraryIndex(s, "pattern.delete", p)
        let pat = s.state[LibraryKey.self].remove(at: i)
        return ["deleted": .string(pat.id)]
    }

    // MARK: Pattern Fill layers

    /// photocraft `placement`: scale (fraction), angle, link and phase of a pattern fill from params.
    static func placement(_ p: JSONValue) -> (Float, Float, Bool, SIMD2<Float>) {
        func num(_ k: String, _ d: Double) -> Float { Float(p[k]?.doubleValue ?? d) }
        var phase = SIMD2<Float>.zero
        if let a = p["phase"]?.arrayValue {
            phase = SIMD2(Float(a.first?.doubleValue ?? 0), Float(a.count > 1 ? a[1].doubleValue ?? 0 : 0))
        }
        return (min(max(num("scale", 100) / 100, 0.01), 10), num("angle", 0), p["link"]?.boolValue ?? true, phase)
    }

    /// The edit of `layer.newFillLayer.pattern`: a Pattern Fill layer of `pat` placed as `p` asks,
    /// above `active`. The Pattern Fill dialog previews it on a copy of the document.
    @discardableResult
    static func insertFillLayer(_ doc: inout Document, _ active: inout LayerId?, _ pat: Pattern, _ p: JSONValue) throws -> LayerId {
        let (scale, angle, link, phase) = placement(p)
        ensureInDoc(&doc, pat)
        let fill = Fill.pattern(PatternFill(name: pat.name, scale: scale, id: pat.id, angle: angle, link: link, phase: phase))
        var l = Layer(name: doc.nextLayerName("Pattern Fill"), content: .fill(fill))
        try CoreCommands.maskNewLayer(doc, &l, p, "layer.newFillLayer.pattern")
        let id = doc.insertAbove(active, l)
        active = id
        return id
    }

    static func newFillLayer(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let pat = try resolveParam(s, "layer.newFillLayer.pattern", p)
        let id = try s.edit("New Pattern Fill Layer") { doc, active in try insertFillLayer(&doc, &active, pat, p) }
        return ["layer": .id(id), "pattern": .string(pat.id)]
    }

    // MARK: Brush texture

    static func brushTexture(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "brush.texturePattern"
        let pat = try resolveParam(s, cmd, p)
        guard pat.isPaintable, Int(exactly: pat.pixelCount) != nil else {
            throw EngineError.bad(cmd, "the pattern is empty or too large to paint")
        }
        // Brush textures are grey: luminance of the composite over white.
        let lum: [Float] = pat.surface.readRGBA(pat.rect).map { q in
            let l = 0.299 * q.x + 0.587 * q.y + 0.114 * q.z
            return l * q.w + (1 - q.w)
        }
        let tile = GrayTile(width: pat.width, height: pat.height, floats: lum)
        s.tools.brush.texture.pattern = .tile(tile)
        s.tools.brush.texture.enabled = p["enabled"]?.boolValue ?? true
        if let sc = p["scale"]?.doubleValue { s.tools.brush.texture.scale = min(max(Float(sc) / 100, 0.01), 10) }
        s.emit(.toolsChanged)
        return ["pattern": .string(pat.id)]
    }

    /// A swatch colour for UIs (average of the tile), straight RGB. A pattern too large to paint is
    /// averaged over its paintable top-left corner.
    static func averageColor(_ p: Pattern) -> PCColor {
        let side = UInt32(Double(Pattern.maxPaintPixels).squareRoot())
        let (w, h) = (min(p.width, side), min(p.height, side))
        let px = p.surface.readRGBA(PixelRect(x0: 0, y0: 0, x1: Int32(w), y1: Int32(h)))
        let n = Float(max(px.count, 1))
        let sum = px.reduce(SIMD3<Float>.zero) { $0 + SIMD3($1.x, $1.y, $1.z) }
        return .rgb(sum.x / n, sum.y / n, sum.z / n)
    }

    // MARK: .pat files

    /// photocraft-io's `pattern_map` errors are plain messages.
    static func patMessage(_ e: any Error) -> String {
        switch e as? PCIOError {
        case .corrupt(let m)?, .unsupported(let m)?: m
        default: "\(e)"
        }
    }

    static func importPat(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "pattern.import"
        guard let path = p["path"]?.stringValue else { throw EngineError.bad(cmd, "missing `path` (.pat file)") }
        let bytes = try FileCommands.readFile(s, path)
        let pats: [Pattern]
        do { pats = try PatternMap.readPat(bytes) } catch { throw EngineError.other(patMessage(error)) }
        var lib = library(s)
        var ids: [JSONValue] = []
        for pat in pats {
            ids.append(.string(pat.id))
            if let i = lib.firstIndex(where: { $0.id == pat.id }) { lib[i] = pat } else { lib.append(pat) }
        }
        s.state[LibraryKey.self] = lib
        return ["imported": .array(ids)]
    }

    static func exportPat(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "pattern.export"
        guard let path = p["path"]?.stringValue else { throw EngineError.bad(cmd, "missing `path`") }
        let pats: [Pattern]
        if let keys = p["patterns"]?.arrayValue {
            pats = try keys.compactMap(\.stringValue).map { k in
                guard let pat = resolve(s, k) else { throw EngineError.bad(cmd, "no pattern \"\(k)\"") }
                return pat
            }
        } else {
            pats = library(s)
        }
        let bytes: [UInt8]
        do { bytes = try PatternMap.writePat(pats) } catch { throw EngineError.other(patMessage(error)) }
        try FileCommands.writeFile(s, path, bytes)
        return ["path": .string(path), "count": .int(pats.count), "bytes": .int(bytes.count)]
    }

    // MARK: Specs

    static func specs() -> [CommandSpec] {
        [
            CommandSpec("edit.definePattern", "Define Pattern…", menu: ["Edit"],
                        params: ##"{"name":text,"rect":[x0,y0,x1,y1]?} → {"pattern":id} (name: default the document's name numbered past the library's names; rect: default the selection bounds or else the canvas; added to the library from the visible composite)"##,
                        module: m, enabled: hasDoc, run: define),
            CommandSpec("pattern.list", "Patterns", params: "{} → [{id,name,width,height,mode,depth,inDocument,inLibrary}]",
                        module: m, journal: false, run: list),
            CommandSpec("pattern.rename", "Rename Pattern", params: ##"{"pattern":id|name,"name":str}"##, module: m, enabled: hasPattern, run: rename),
            CommandSpec("pattern.delete", "Delete Pattern", params: ##"{"pattern":id|name} (library only; documents keep their copy)"##,
                        module: m, enabled: hasPattern, run: delete),
            CommandSpec("pattern.import", "Import Patterns…", params: ##"{"path":".pat file"}"##, module: m, run: importPat),
            CommandSpec("pattern.export", "Export Patterns…",
                        params: ##"{"path":".pat file","patterns":[id|name]? (default: the whole library)}"##, module: m, enabled: hasPattern, run: exportPat),
            CommandSpec("layer.newFillLayer.pattern", "Pattern…", menu: ["Layer", "New Fill Layer"],
                        params: ##"{"pattern":id|name?=first library pattern,"scale":1..1000=100,"angle":deg=0,"link":bool=true,"phase":[x,y]?,"path":"work"|saved path name|{…path}? (the active path: becomes the vector mask; else the selection is the layer mask)}"##,
                        module: m, enabled: hasDoc, run: newFillLayer),
            CommandSpec("brush.texturePattern", "Brush Texture Pattern",
                        params: ##"{"pattern":id|name,"scale":1..1000?,"enabled":bool=true} (sets the session brush's Texture to that pattern)"##,
                        module: m, enabled: hasPattern, run: brushTexture),
        ]
    }
}
