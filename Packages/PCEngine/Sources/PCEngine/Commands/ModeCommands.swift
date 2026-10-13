// Port of photocraft-engine (crates/engine/src/mode_cmds.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Image menu remnants: Image Rotation › Arbitrary (`ModeCommands+Rotate.swift`), and the palette /
// ink modes — Mode › Indexed Color, Color Table, Bitmap and Duotone.
//
// Indexed, Bitmap and Duotone documents keep expanded pixels (RGB 8-bit / Gray 8-bit / Gray, see
// `Document.pixelFormat`): Indexed and Bitmap quantise the flattened image in place and record the
// palette (`Document.colorTable`) or the 1-bit look; Duotone keeps the gray pixels and the inks
// (`Document.duotone`), which display and flat export render through. Like Photoshop the
// conversions flatten (Indexed, Bitmap) and require a grayscale source (Bitmap, Duotone). The
// palette construction, dithering and 1-bit methods are a local CPU port of photocraft-algo's
// `quantize` (`ModeCommands.Quantize`).

import Foundation
import PCDocument
import PCFoundation

public enum ModeCommands: CommandModule {
    public static let name = "mode_cmds"
    static let m = "mode_cmds"

    static func bad(_ cmd: String, _ msg: String) -> EngineError { .bad(cmd, msg) }

    static func modeIs(_ modes: [ColorMode], _ what: String) -> CommandEnabled {
        { s, _ in
            guard let d = s.active else { return "no document open" }
            return modes.contains(d.doc.mode) ? nil : "\(what) (the document is \(ColorCommands.modeName(d.doc.mode)))"
        }
    }

    // MARK: Flatten helpers

    /// The flattened image as straight RGBA (over white when `opaque`).
    static func composite(_ s: Session, _ doc: Document, opaque: Bool) throws -> [SIMD4<Float>] {
        let px = try s.services.renderer.render(doc, region: doc.bounds).px
        guard opaque else { return px }
        return px.map { p in
            let a = min(max(p.w, 0), 1)
            return SIMD4(p.x * a + (1 - a), p.y * a + (1 - a), p.z * a + (1 - a), 1)
        }
    }

    /// Replaces the document's layers by one 8-bit layer holding `px` in `mode`'s storage format
    /// (photocraft `single_layer`).
    static func singleLayer(_ doc: inout Document, _ active: inout LayerId?, _ mode: ColorMode, _ px: [SIMD4<Float>], _ name: String, background: Bool) {
        doc.mode = mode
        doc.depth = .u8
        let fmt = doc.pixelFormat
        var data = [Float]()
        data.reserveCapacity(px.count * fmt.channels)
        for q in px { data += fmt.components(fromRGBA: q) }
        var l = Layer.raster(name, format: fmt)
        if background {
            l.locks.transparency = true
            l.locks.position = true
        }
        let bounds = doc.bounds
        if data.count >= bounds.area * fmt.channels { l.withRaster { $0.writeRegion(bounds, data) } }
        active = l.id
        doc.layers = [l]
        for i in doc.channels.indices {
            let f = PixelFormat(mode: .grayscale, sample: .u8, alpha: doc.channels[i].surface.format.alpha)
            doc.channels[i].surface = doc.channels[i].surface.convertedAny(to: f)
        }
        doc.quickMask = nil
        doc.colorTable = nil
        doc.duotone = nil
    }

    // MARK: Indexed Color / Color Table

    static func indexedColor(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "image.mode.indexedColor"
        guard let kind = Quantize.PaletteKind(id: p["palette"]?.stringValue ?? "selective") else {
            throw bad(cmd, "palette: exact|systemMac|systemWindows|web|uniform|perceptual|selective|adaptive")
        }
        guard let forced = Quantize.Forced(id: p["forced"]?.stringValue ?? "blackWhite") else { throw bad(cmd, "forced: none|blackWhite|primaries|web") }
        guard let dither = Quantize.Dither(id: p["dither"]?.stringValue ?? "diffusion") else { throw bad(cmd, "dither: none|diffusion|pattern|noise") }
        var colors = 256
        if let v = p["colors"] {
            guard let n = v.doubleValue, n.isFinite, n == n.rounded(.towardZero), n >= 2, n <= 256 else {
                throw bad(cmd, "colors must be an integer from 2 to 256")
            }
            colors = Int(n)
        }
        let amount = min(max(p["amount"]?.floatValue ?? 75, 0), 100) / 100
        let transparency = p["transparency"]?.boolValue ?? true
        let renderer = s.services.renderer
        let (count, transparent): (Int, Int?) = try s.edit("Indexed Color") { doc, active in
            var px = try renderer.render(doc, region: doc.bounds).px
            if !transparency { px = px.map { q in let a = min(max(q.w, 0), 1); return SIMD4(q.x * a + 1 - a, q.y * a + 1 - a, q.z * a + 1 - a, 1) } }
            let hasClear = transparency && px.contains { $0.w < 0.5 }
            var pal: [SIMD3<UInt8>]
            do { pal = try Quantize.buildPalette(px, kind, hasClear ? max(colors - 1, 2) : colors, forced) } catch {
                throw bad(cmd, (error as? Quantize.Failure)?.message ?? "\(error)")
            }
            var transparent: Int?
            if hasClear && pal.count < 256 {
                pal.append(SIMD3(255, 255, 255))
                transparent = pal.count - 1
            }
            Quantize.quantize(&px, width: doc.size.width, pal, dither, amount: amount, transparent: transparent)
            singleLayer(&doc, &active, .indexed, px, transparent != nil ? "Index" : "Background", background: transparent == nil)
            doc.colorTable = ColorTable(colors: pal, transparent: transparent.map { UInt8($0) })
            return (pal.count, transparent)
        }
        return ["colors": .int(count), "transparentIndex": transparent.map { .int($0) } ?? .null]
    }

    static func hex(_ c: SIMD3<UInt8>) -> String { String(format: "#%02x%02x%02x", c.x, c.y, c.z) }

    static func parseColor(_ v: JSONValue) -> SIMD3<UInt8>? {
        switch v {
        case .string(let s):
            let h = Array(s.drop { $0 == "#" }.utf8)
            func b(_ i: Int) -> UInt8? { i + 2 <= h.count ? UInt8(String(decoding: h[i..<(i + 2)], as: UTF8.self), radix: 16) : nil }
            guard let r = b(0), let g = b(2), let bl = b(4) else { return nil }
            return SIMD3(r, g, bl)
        case .array(let a) where a.count >= 3:
            func c(_ i: Int) -> UInt8? { a[i].doubleValue.map { UInt8(min(max($0.rounded(), 0), 255)) } }
            guard let r = c(0), let g = c(1), let b = c(2) else { return nil }
            return SIMD3(r, g, b)
        default:
            return nil
        }
    }

    /// Built-in Color Table presets (photocraft `preset_table`).
    public static func presetTable(_ name: String) -> [SIMD3<UInt8>]? {
        func ramp(_ f: (Float) -> SIMD3<Float>) -> [SIMD3<UInt8>] {
            (0..<256).map { i in
                let v = f(Float(i) / 255)
                func q(_ x: Float) -> UInt8 { UInt8((min(max(x, 0), 1) * 255).rounded()) }
                return SIMD3(q(v.x), q(v.y), q(v.z))
            }
        }
        switch name {
        case "grayscale": return ramp { SIMD3(repeating: $0) }
        // Black → red → yellow → white, the incandescence scale.
        case "blackBody": return ramp { t in SIMD3(min(t * 3, 1), min(max(t * 3 - 1, 0), 1), min(max(t * 3 - 2, 0), 1)) }
        case "spectrum":
            return ramp { t in
                let h = t * 300 / 60
                let x = 1 - abs(h.truncatingRemainder(dividingBy: 2) - 1)
                switch Int(h) {
                case 0: return SIMD3(1, x, 0)
                case 1: return SIMD3(x, 1, 0)
                case 2: return SIMD3(0, 1, x)
                case 3: return SIMD3(0, x, 1)
                default: return SIMD3(x, 0, 1)
                }
            }
        case "systemMac", "system": return Quantize.macPalette()
        case "systemWindows": return Quantize.windowsPalette()
        case "web": return Quantize.webPalette()
        default: return nil
        }
    }

    static func tableReport(_ t: ColorTable) -> JSONValue {
        ["colors": .strings(t.colors.map(hex)), "transparent": t.transparent.map { .int(Int($0)) } ?? .null]
    }

    /// Image › Mode › Color Table: replace entries (pixels keep their index, so their colour follows
    /// the table) and set the transparent entry. No changes: report the table.
    static func colorTable(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "image.mode.colorTable"
        guard let d = s.active else { throw EngineError.noDocument }
        guard let cur = d.doc.colorTable else { throw EngineError.other("the document has no color table") }
        var table = cur
        let tname = p["table"]?.stringValue ?? "custom"
        if tname != "custom" {
            guard let t = presetTable(tname) else { throw bad(cmd, "unknown table `\(tname)`") }
            table.colors = t
        }
        if let a = p["colors"]?.arrayValue {
            let c = a.map(parseColor)
            guard !c.contains(where: { $0 == nil }) else { throw bad(cmd, ##"colors: ["#rrggbb" | [r, g, b], …]"##) }
            if c.isEmpty || c.count > 256 { throw bad(cmd, "a color table has 1 to 256 entries") }
            table.colors = c.compactMap { $0 }
        }
        if let e = p["entries"]?.objectValue {
            // serde_json maps iterate in key order.
            for (k, v) in e.sorted(by: { $0.key < $1.key }) {
                guard let i = Int(k), i >= 0 else { throw bad(cmd, "entry index `\(k)`") }
                guard let c = parseColor(v) else { throw bad(cmd, "entry \(i): bad colour") }
                if i >= table.colors.count { throw bad(cmd, "entry \(i) is past the table (\(table.colors.count) entries)") }
                table.colors[i] = c
            }
        }
        switch p["transparent"] {
        case .null?: table.transparent = nil
        case let v?:
            if let i = v.uint64Value, Int(exactly: i).map({ $0 < table.colors.count }) == true { table.transparent = UInt8(i) }
        case nil: break
        }
        if table == cur { return tableReport(cur) }
        let out = tableReport(table)
        let old = cur, new = table
        try s.edit("Color Table") { doc, _ in
            for i in doc.layers.indices {
                doc.updateLayer(at: [i]) { l in
                    l.withRaster { surf in
                        let r = surf.contentBounds
                        if r.isEmpty { return }
                        let fmt = surf.format, n = fmt.channels
                        var data = surf.readRegion(r)
                        var o = 0
                        while o + n <= data.count {
                            defer { o += n }
                            let c = PixelCodec.toRGBA(fmt, Array(data[o..<(o + n)]))
                            let rgb = SIMD3(c.x, c.y, c.z)
                            let idx: Int
                            if c.w <= 0 {
                                guard let t = old.transparent.map(Int.init), t < old.colors.count, old.rgb(t) == rgb else { continue }
                                idx = t
                            } else {
                                idx = old.nearest(rgb)
                            }
                            let alpha: Float = new.transparent.map(Int.init) == idx ? 0 : (c.w <= 0 ? 1 : c.w)
                            let nc = idx < new.colors.count ? new.rgb(idx) : new.rgb(new.nearest(rgb))
                            let enc = fmt.components(fromRGBA: SIMD4(nc, alpha))
                            for k in 0..<min(n, enc.count) { data[o + k] = enc[k] }
                        }
                        surf.writeRegion(r, data)
                        surf.prune()
                    }
                }
            }
            doc.colorTable = new
        }
        return out
    }

    // MARK: Bitmap

    static func bitmap(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "image.mode.bitmap"
        guard let d = s.active else { throw EngineError.noDocument }
        let dpi = max(d.doc.resolutionDpi, 1)
        let method: Quantize.BitmapMethod
        switch p["method"]?.stringValue ?? "diffusion" {
        case "threshold", "threshold50": method = .threshold
        case "pattern": method = .pattern
        case "diffusion": method = .diffusion
        case "halftone":
            let freq = min(max(p["frequency"]?.floatValue ?? 53, 1), 999)
            guard let shape = Quantize.HalftoneShape(rawValue: p["shape"]?.stringValue ?? "round") else {
                throw bad(cmd, "shape: round|ellipse|line|square|diamond|cross")
            }
            method = .halftone(cell: max(dpi / freq, 2), angle: p["angle"]?.floatValue ?? 45, shape: shape)
        case let other:
            throw bad(cmd, "method `\(other)` (threshold|pattern|diffusion|halftone)")
        }
        let renderer = s.services.renderer
        try s.edit("Bitmap") { doc, active in
            let px = try renderer.render(doc, region: doc.bounds).px.map { p in
                let a = min(max(p.w, 0), 1)
                return SIMD3(p.x * a + 1 - a, p.y * a + 1 - a, p.z * a + 1 - a)
            }
            var gray = px.map { ColorConvert.rgbToGray($0) }
            Quantize.toBitmap(&gray, width: doc.size.width, method)
            singleLayer(&doc, &active, .bitmap, gray.map { SIMD4($0, $0, $0, 1) }, "Background", background: true)
        }
        return .null
    }

    // MARK: Duotone

    /// Default inks per type: black first, then warm brown, gold and slate blue.
    static func defaultInks(_ n: Int) -> [DuotoneInk] {
        let all: [(String, SIMD3<Float>)] = [("Black", SIMD3(0, 0, 0)), ("Warm Brown", SIMD3(0.62, 0.38, 0.18)), ("Gold", SIMD3(0.86, 0.68, 0.18)),
                                             ("Slate Blue", SIMD3(0.27, 0.38, 0.58))]
        return all.prefix(max(n, 0)).map { DuotoneInk(name: $0.0, color: $0.1) }
    }

    static func parseInks(_ cmd: String, _ v: JSONValue, _ n: Int) throws -> [DuotoneInk] {
        guard let a = v.arrayValue else { throw bad(cmd, ##"inks: [{"name","color":"#rrggbb","curve":[[in,out],…] (0..100)}, …]"##) }
        let defaults = defaultInks(min(max(n, a.count), 4))
        var out: [DuotoneInk] = []
        for (i, ink) in a.prefix(4).enumerated() {
            var d = i < defaults.count ? defaults[i] : DuotoneInk(name: "Ink \(i + 1)", color: .zero)
            if let name = ink["name"]?.stringValue { d.name = name }
            if let c = ink["color"].flatMap(parseColor) { d.color = SIMD3(Float(c.x) / 255, Float(c.y) / 255, Float(c.z) / 255) }
            if let pts = ink["curve"]?.arrayValue {
                var curve: [CurvePoint] = pts.compactMap { q in
                    guard let i = q[0]?.doubleValue, let o = q[1]?.doubleValue else { return nil }
                    return CurvePoint(input: Float(i) / 100, output: Float(o) / 100)
                }
                curve = curve.enumerated().sorted { a, b in
                    a.element.input != b.element.input ? Quantize.totalLess(a.element.input, b.element.input) : a.offset < b.offset
                }.map(\.element)
                if curve.count >= 2 { d.curve = curve }
            }
            out.append(d)
        }
        return out
    }

    static func duotone(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "image.mode.duotone"
        let n: Int
        switch p["type"]?.stringValue ?? "duotone" {
        case "monotone": n = 1
        case "duotone": n = 2
        case "tritone": n = 3
        case "quadtone": n = 4
        case let t: throw bad(cmd, "type `\(t)` (monotone|duotone|tritone|quadtone)")
        }
        var inks = try p["inks"].map { try parseInks(cmd, $0, n) } ?? defaultInks(n)
        if inks.count < n { inks += defaultInks(n).dropFirst(inks.count) }
        inks = Array(inks.prefix(n))
        let names = inks.map(\.name)
        let set = inks
        try s.edit("Duotone") { doc, _ in
            doc.mode = .duotone
            doc.duotone = Duotone(inks: set)
            doc.colorTable = nil
        }
        return ["inks": .strings(names)]
    }

    /// The gradient-map layer that renders Duotone inks over the gray composite.
    public static func duotoneDisplayLayer(_ d: Duotone) -> Layer { Layer(name: "Duotone", content: .adjustment(d.displayAdjustment)) }

    /// A copy of `doc` that displays like the printed result (Duotone inks), or nil when the
    /// document displays as stored.
    public static func displayDocument(_ doc: Document) -> Document? {
        guard doc.mode == .duotone, let d = doc.duotone else { return nil }
        var out = doc
        out.layers.append(duotoneDisplayLayer(d))
        return out
    }

    // MARK: Registration

    public static func register(into r: inout CommandRegistry) {
        r.add([
            CommandSpec("image.rotation.arbitrary", "Arbitrary…", menu: ["Image", "Image Rotation"],
                        params: #"{"angle":-359.99..359.99=0,"direction":"cw|ccw"="cw","interpolation":"bicubic|bilinear|nearest"="bicubic"}"#,
                        module: m, enabled: Pre.hasDoc, run: rotateArbitrary),
            CommandSpec("image.mode.indexedColor", "Indexed Color…", menu: ["Image", "Mode"],
                        params: #"{"palette":"selective|perceptual|adaptive|exact|systemMac|systemWindows|web|uniform"="selective","colors":2..256=256,"forced":"blackWhite|none|primaries|web"="blackWhite","transparency":bool=true,"dither":"diffusion|none|pattern|noise"="diffusion","amount":0..100=75} (flattens)"#,
                        module: m, enabled: modeIs([.rgb, .grayscale, .indexed, .duotone, .cmyk, .lab], "Indexed Color needs an RGB or Grayscale image"),
                        run: indexedColor),
            CommandSpec("image.mode.colorTable", "Color Table…", menu: ["Image", "Mode"],
                        params: ##"{"table":"custom|blackBody|grayscale|spectrum|systemMac|systemWindows|web"="custom","colors":json,"entries":json,"transparent":json} (colors: ["#rrggbb", …]; entries: {"index": "#rrggbb"}; transparent: index|null)"##,
                        module: m, enabled: modeIs([.indexed], "Color Table needs an Indexed Color image"), run: colorTable),
            CommandSpec("image.mode.bitmap", "Bitmap…", menu: ["Image", "Mode"],
                        params: #"{"method":"diffusion|threshold|pattern|halftone"="diffusion","frequency":1..999=53,"angle":-180..180=45,"shape":"round|ellipse|line|square|diamond|cross"="round"} (halftone frequency in lines/inch; flattens)"#,
                        module: m, enabled: modeIs([.grayscale], "Bitmap needs a Grayscale image (Image › Mode › Grayscale first)"), run: bitmap),
            CommandSpec("image.mode.duotone", "Duotone…", menu: ["Image", "Mode"],
                        params: ##"{"type":"duotone|monotone|tritone|quadtone"="duotone","inks":json} (inks: [{"name","color":"#rrggbb","curve":[[in,out],…] in 0..100}, …])"##,
                        module: m, enabled: modeIs([.grayscale, .duotone], "Duotone needs a Grayscale image (Image › Mode › Grayscale first)"),
                        run: duotone),
        ])
    }
}

// MARK: - Quantize (CPU port of photocraft-algo's quantize.rs)

extension ModeCommands {
    /// Colour reduction for Indexed Color and Bitmap (photocraft-algo `quantize`): palette
    /// construction (exact, system, web, uniform, perceptual, selective, adaptive), forced colours,
    /// dithering (none, Floyd–Steinberg diffusion, ordered pattern, noise), and 1-bit conversion.
    /// Buffers are straight RGBA in 0…1, row-major. Median cut follows Heckbert (1982); k-means
    /// refinement is Lloyd's algorithm; error diffusion is Floyd & Steinberg (1976). The nearest
    /// colour search is exact (ties to the lowest palette index), as photocraft's.
    enum Quantize {
        typealias RGB8 = SIMD3<UInt8>

        struct Failure: Error { let message: String }

        enum PaletteKind: Equatable {
            case exact, systemMac, systemWindows, web, uniform, perceptual, selective, adaptive

            init?(id: String) {
                switch id {
                case "exact": self = .exact
                case "system", "systemMac", "systemMacOs": self = .systemMac
                case "systemWindows": self = .systemWindows
                case "web": self = .web
                case "uniform": self = .uniform
                case "perceptual", "localPerceptual": self = .perceptual
                case "selective", "localSelective": self = .selective
                case "adaptive", "localAdaptive": self = .adaptive
                default: return nil
                }
            }
        }

        enum Forced {
            case none, blackWhite, primaries, web

            init?(id: String) {
                switch id {
                case "none": self = .none
                case "blackWhite", "blackAndWhite": self = .blackWhite
                case "primaries": self = .primaries
                case "web": self = .web
                default: return nil
                }
            }
        }

        enum Dither {
            case none, diffusion, pattern, noise

            init?(id: String) {
                switch id {
                case "none": self = .none
                case "diffusion": self = .diffusion
                case "pattern": self = .pattern
                case "noise": self = .noise
                default: return nil
                }
            }
        }

        /// Rust's `f32::total_cmp` less-than for the values here (-0 before +0).
        static func totalLess(_ a: Float, _ b: Float) -> Bool {
            if a != b { return a < b }
            return a.sign == .minus && b.sign == .plus
        }

        static func to8(_ v: Float) -> UInt8 { UInt8((min(max(v, 0), 1) * 255).rounded()) }

        /// The 216-colour web-safe cube.
        static func webPalette() -> [RGB8] {
            var v: [RGB8] = []
            for r in 0..<6 { for g in 0..<6 { for b in 0..<6 { v.append(RGB8(UInt8(r * 51), UInt8(g * 51), UInt8(b * 51))) } } }
            return v
        }

        /// Classic Mac OS system palette: the web cube plus red, green, blue and gray ramps.
        static func macPalette() -> [RGB8] {
            var v = webPalette()
            let steps = (1...15).map { UInt8($0 * 17) }.filter { $0 % 51 != 0 }
            for s in steps.reversed() { v.append(RGB8(s, 0, 0)) }
            for s in steps.reversed() { v.append(RGB8(0, s, 0)) }
            for s in steps.reversed() { v.append(RGB8(0, 0, s)) }
            for s in steps.reversed() { v.append(RGB8(s, s, s)) }
            return Array(v.prefix(256))
        }

        /// Windows default palette: the 20 static system colours plus the web cube and a gray ramp.
        static func windowsPalette() -> [RGB8] {
            var v: [RGB8] = [
                [0, 0, 0], [128, 0, 0], [0, 128, 0], [128, 128, 0], [0, 0, 128], [128, 0, 128], [0, 128, 128], [192, 192, 192], [192, 220, 192],
                [166, 202, 240], [255, 251, 240], [160, 160, 164], [128, 128, 128], [255, 0, 0], [0, 255, 0], [255, 255, 0], [0, 0, 255],
                [255, 0, 255], [0, 255, 255], [255, 255, 255],
            ]
            for c in webPalette() where !v.contains(c) { v.append(c) }
            var g: UInt8 = 8
            while v.count < 256 {
                if !v.contains(RGB8(g, g, g)) { v.append(RGB8(g, g, g)) }
                g = g &+ 12
            }
            return v
        }

        /// Up to `n` colours on an equal-step RGB grid.
        static func uniformPalette(_ n: Int) -> [RGB8] {
            let k = max(Int(cbrtf(Float(n)).rounded(.down)), 2)
            func lv(_ i: Int) -> UInt8 { UInt8((Float(i) / Float(k - 1) * 255).rounded()) }
            var v: [RGB8] = []
            for r in 0..<k { for g in 0..<k { for b in 0..<k { v.append(RGB8(lv(r), lv(g), lv(b))) } } }
            return v
        }

        static func forcedColors(_ f: Forced) -> [RGB8] {
            switch f {
            case .none: []
            case .blackWhite: [[0, 0, 0], [255, 255, 255]]
            case .primaries: [[0, 0, 0], [255, 255, 255], [255, 0, 0], [0, 255, 0], [0, 0, 255], [0, 255, 255], [255, 0, 255], [255, 255, 0]]
            case .web: webPalette()
            }
        }

        /// Unique 8-bit colours with counts (opaque pixels only), sorted.
        static func histogram(_ px: [SIMD4<Float>]) -> [(RGB8, UInt32)] {
            var m: [UInt32: UInt32] = [:]
            for p in px where p.w >= 0.5 {
                let k = UInt32(to8(p.x)) << 16 | UInt32(to8(p.y)) << 8 | UInt32(to8(p.z))
                m[k, default: 0] += 1
            }
            return m.keys.sorted().map { k in (RGB8(UInt8(k >> 16), UInt8((k >> 8) & 255), UInt8(k & 255)), m[k] ?? 0) }
        }

        typealias Point = (SIMD3<Float>, UInt32)

        /// Median cut over weighted points into at most `n` boxes; returns box means.
        static func medianCut(_ pts: [Point], _ n: Int) -> [SIMD3<Float>] {
            if pts.isEmpty || n == 0 { return [] }
            var boxes: [[Point]] = [pts]
            while boxes.count < n {
                // Split the box with the largest weighted extent (the first one on ties).
                var best: (Int, Int, Float) = (-1, 0, -1)
                for (i, b) in boxes.enumerated() where b.count > 1 {
                    var axis = (0, Float(-1))
                    for a in 0..<3 {
                        var lo = Float.greatestFiniteMagnitude, hi = -Float.greatestFiniteMagnitude
                        for p in b { lo = min(lo, p.0[a]); hi = max(hi, p.0[a]) }
                        if hi - lo > axis.1 { axis = (a, hi - lo) }
                    }
                    let w = b.reduce(Float(0)) { $0 + Float($1.1) }
                    let score = axis.1 * w.squareRoot()
                    if score > best.2 { best = (i, axis.0, score) }
                }
                if best.0 < 0 || best.2 <= 0 { break }
                let bi = best.0, axis = best.1
                // Rust's `swap_remove`.
                var b = boxes[bi]
                if bi == boxes.count - 1 { boxes.removeLast() } else { boxes[bi] = boxes.removeLast() }
                // A stable sort along the axis.
                b = b.enumerated().sorted { x, y in
                    let (a, c) = (x.element.0[axis], y.element.0[axis])
                    if totalLess(a, c) { return true }
                    if totalLess(c, a) { return false }
                    return x.offset < y.offset
                }.map(\.element)
                let total = b.reduce(UInt64(0)) { $0 + UInt64($1.1) }
                var acc: UInt64 = 0
                var cut = 1
                for (i, p) in b.enumerated() {
                    acc += UInt64(p.1)
                    if acc * 2 >= total {
                        cut = min(max(i + 1, 1), b.count - 1)
                        break
                    }
                }
                boxes.append(Array(b[..<cut]))
                boxes.append(Array(b[cut...]))
            }
            return boxes.map { b in
                let w = b.reduce(0.0) { $0 + Double($1.1) }
                var mean = SIMD3<Float>()
                for a in 0..<3 { mean[a] = Float(b.reduce(0.0) { $0 + Double($1.0[a]) * Double($1.1) } / w) }
                return mean
            }
        }

        /// Exact nearest entry: squared distance, ties to the lowest index.
        static func nearest(_ entries: [SIMD3<Float>], _ p: SIMD3<Float>) -> Int {
            var best: (Float, Int) = (.greatestFiniteMagnitude, 0)
            for (i, e) in entries.enumerated() {
                let d0 = e.x - p.x, d1 = e.y - p.y, d2 = e.z - p.z
                let d = d0 * d0 + d1 * d1 + d2 * d2
                if d < best.0 { best = (d, i) }
            }
            return best.1
        }

        /// Lloyd refinement of `centers` over weighted points.
        static func kmeans(_ pts: [Point], _ centers: inout [SIMD3<Float>], iterations: Int) {
            if centers.isEmpty { return }
            for _ in 0..<iterations {
                var sum = [SIMD3<Double>](repeating: .zero, count: centers.count)
                var cnt = [Double](repeating: 0, count: centers.count)
                for (p, w) in pts {
                    let i = nearest(centers, p)
                    sum[i] += SIMD3(Double(p.x), Double(p.y), Double(p.z)) * Double(w)
                    cnt[i] += Double(w)
                }
                for i in centers.indices where cnt[i] > 0 {
                    let m = sum[i] / cnt[i]
                    centers[i] = SIMD3(Float(m.x), Float(m.y), Float(m.z))
                }
            }
        }

        static func labToRGB8(_ lab: SIMD3<Float>) -> RGB8 {
            let v = ColorConvert.labToSRGB(lab)
            return RGB8(to8(v.x), to8(v.y), to8(v.z))
        }

        /// The palette for `px` (photocraft `build_palette`). `colors` is the requested count
        /// (2…256) for the computed kinds; forced colours come first and count toward it.
        static func buildPalette(_ px: [SIMD4<Float>], _ kind: PaletteKind, _ colors: Int, _ forced: Forced) throws(Failure) -> [RGB8] {
            let colors = min(max(colors, 2), 256)
            var pal = forcedColors(forced)
            let room = max(colors - pal.count, 0)
            let computedKind = kind == .adaptive || kind == .perceptual || kind == .selective
            let hist = kind == .exact || (room > 0 && computedKind) ? histogram(px) : []
            let computed: [RGB8]
            switch kind {
            case .exact:
                if hist.count > 256 { throw Failure(message: "the image has \(hist.count) colours; Exact needs 256 or fewer") }
                computed = hist.map(\.0)
            case .systemMac: computed = macPalette()
            case .systemWindows: computed = windowsPalette()
            case .web: computed = webPalette()
            case .uniform: computed = uniformPalette(max(room, 8))
            case .adaptive:
                if hist.count <= room {
                    computed = hist.map(\.0)
                } else {
                    let pts: [Point] = hist.map { (SIMD3(Float($0.0.x), Float($0.0.y), Float($0.0.z)), $0.1) }
                    var centers = medianCut(pts, room)
                    kmeans(pts, &centers, iterations: 2)
                    computed = centers.map { c in
                        func q(_ v: Float) -> UInt8 { UInt8(min(max(v.rounded(), 0), 255)) }
                        return RGB8(q(c.x), q(c.y), q(c.z))
                    }
                }
            case .perceptual, .selective:
                if hist.count <= room {
                    computed = hist.map(\.0)
                } else {
                    let pts: [Point] = hist.map { (ColorConvert.srgbToLab(SIMD3(Float($0.0.x) / 255, Float($0.0.y) / 255, Float($0.0.z) / 255)), $0.1) }
                    var centers = medianCut(pts, room)
                    kmeans(pts, &centers, iterations: 4)
                    var v = centers.map(labToRGB8)
                    if kind == .selective {
                        // Favour web-safe colours: snap entries within ~10 levels of one.
                        for i in v.indices {
                            let c = v[i]
                            func snap(_ x: UInt8) -> UInt8 { UInt8(min((Float(x) / 51).rounded() * 51, 255)) }
                            let sn = RGB8(snap(c.x), snap(c.y), snap(c.z))
                            if (0..<3).allSatisfy({ abs(Int(c[$0]) - Int(sn[$0])) <= 10 }) { v[i] = sn }
                        }
                    }
                    computed = v
                }
            }
            for c in computed {
                if pal.count >= 256 { break }
                if !pal.contains(c) { pal.append(c) }
            }
            if computedKind || kind == .uniform { pal = Array(pal.prefix(max(colors, forcedColors(forced).count))) }
            if pal.isEmpty { pal.append(RGB8(0, 0, 0)) }
            return pal
        }

        static let bayer: [UInt8] = [
            0, 32, 8, 40, 2, 34, 10, 42, 48, 16, 56, 24, 50, 18, 58, 26, 12, 44, 4, 36, 14, 46, 6, 38, 60, 28, 52, 20, 62, 30, 54, 22, 3, 35, 11, 43, 1, 33, 9, 41,
            51, 19, 59, 27, 49, 17, 57, 25, 15, 47, 7, 39, 13, 45, 5, 37, 63, 31, 55, 23, 61, 29, 53, 21,
        ]

        /// 8×8 Bayer threshold in -0.5…0.5.
        static func bayer8(_ x: Int, _ y: Int) -> Float { (Float(bayer[(y % 8) * 8 + x % 8]) + 0.5) / 64 - 0.5 }

        static func hash01(_ x: Int, _ y: Int, _ seed: UInt32) -> Float {
            var h = UInt32(truncatingIfNeeded: x) &* 0x8da6_b343 ^ UInt32(truncatingIfNeeded: y) &* 0xd816_3841 ^ seed &* 0xcb1a_b31f
            h ^= h >> 13
            h = h &* 0x5bd1_e995
            h ^= h >> 15
            return Float(h & 0xffff) / 65535
        }

        /// Maps every opaque pixel to its palette entry (in place) with the chosen dither; returns
        /// the index per pixel. Pixels with alpha < ½ become entry `transparent` (and alpha 0) when
        /// given; otherwise alpha is kept. `amount` (0…1) scales the dither strength.
        @discardableResult
        static func quantize(_ px: inout [SIMD4<Float>], width w: Int, _ pal: [RGB8], _ dither: Dither, amount: Float, transparent: Int?) -> [UInt8] {
            let entries = pal.map { SIMD3(Float($0.x), Float($0.y), Float($0.z)) }
            let h = w > 0 ? px.count / w : 0
            var idx = [UInt8](repeating: 0, count: px.count)
            let a = min(max(amount, 0), 1)
            // Typical palette spacing sets the ordered/noise dither amplitude.
            let spread = min(1 / max(cbrtf(Float(pal.count)), 1), 0.5) * a
            var err = [SIMD3<Float>](repeating: .zero, count: 2 * (w + 2))
            for y in 0..<h {
                if dither == .diffusion {
                    // Rows ping-pong: `cur` is row y, `next` row y + 1 (offset by one for x = -1).
                    for x in 0..<(w + 2) {
                        err[x] = err[w + 2 + x]
                        err[w + 2 + x] = .zero
                    }
                }
                for x in 0..<w {
                    let i = y * w + x
                    let p = px[i]
                    if p.w < 0.5 {
                        if let t = transparent {
                            idx[i] = UInt8(truncatingIfNeeded: t)
                            px[i] = .zero
                            continue
                        }
                        if p.w <= 0 { continue }
                    }
                    var c = SIMD3(p.x, p.y, p.z)
                    switch dither {
                    case .none: break
                    case .diffusion: c += err[x + 1]
                    case .pattern: c += SIMD3(repeating: bayer8(x, y) * spread)
                    case .noise: c += SIMD3(repeating: (hash01(x, y, 7) - 0.5) * spread)
                    }
                    c = SIMD3(min(max(c.x, 0), 1), min(max(c.y, 0), 1), min(max(c.z, 0), 1))
                    let k = nearest(entries, c * 255)
                    idx[i] = UInt8(truncatingIfNeeded: k)
                    let e = entries[k] / 255
                    if dither == .diffusion {
                        let d = (c - e) * a
                        err[x + 2] += d * 7 / 16
                        err[w + 2 + x] += d * 3 / 16
                        err[w + 2 + x + 1] += d * 5 / 16
                        err[w + 2 + x + 2] += d / 16
                    }
                    px[i] = SIMD4(e, transparent != nil ? 1 : p.w)
                }
            }
            return idx
        }

        /// Image › Mode › Bitmap methods.
        enum BitmapMethod {
            case threshold, pattern, diffusion
            /// Halftone screen: cell size (px), angle in degrees, dot shape.
            case halftone(cell: Float, angle: Float, shape: HalftoneShape)
        }

        enum HalftoneShape: String {
            case round, ellipse, line, square, diamond, cross
        }

        /// Spot function in 0…1 for a position (u, v) in -1…1 within a halftone cell.
        static func spot(_ shape: HalftoneShape, _ u: Float, _ v: Float) -> Float {
            let s: Float
            switch shape {
            case .round: s = 1 - (u * u + v * v) / 2
            case .ellipse: s = 1 - (u * u + 0.6 * v * v) / 1.6
            case .line: s = 1 - abs(v)
            case .square: s = 1 - max(abs(u), abs(v))
            case .diamond: s = 1 - (abs(u) + abs(v)) / 2
            case .cross: s = 1 - min(abs(u), abs(v))
            }
            return min(max(s, 0), 1)
        }

        static func remEuclid1(_ v: Float) -> Float {
            let r = v.truncatingRemainder(dividingBy: 1)
            return r < 0 ? r + 1 : r
        }

        /// Converts gray values (0…1, row-major `w` wide) to 0/1 in place.
        static func toBitmap(_ gray: inout [Float], width w: Int, _ method: BitmapMethod) {
            let h = w > 0 ? gray.count / w : 0
            switch method {
            case .threshold:
                for i in gray.indices { gray[i] = gray[i] >= 0.5 ? 1 : 0 }
            case .pattern:
                for i in gray.indices { gray[i] = gray[i] > bayer8(i % max(w, 1), i / max(w, 1)) + 0.5 ? 1 : 0 }
            case .diffusion:
                var buf = gray
                for y in 0..<h {
                    for x in 0..<w {
                        let i = y * w + x
                        let old = buf[i]
                        let new: Float = old >= 0.5 ? 1 : 0
                        let e = old - new
                        gray[i] = new
                        if x + 1 < w { buf[i + 1] += e * 7 / 16 }
                        if y + 1 < h {
                            if x > 0 { buf[i + w - 1] += e * 3 / 16 }
                            buf[i + w] += e * 5 / 16
                            if x + 1 < w { buf[i + w + 1] += e / 16 }
                        }
                    }
                }
            case .halftone(let cell0, let angle, let shape):
                let cell = max(cell0, 2)
                let r = angle * .pi / 180
                let (s, c) = (sin(r), cos(r))
                // Rank the spot function over the cell so coverage is proportional to the tone.
                var table: [Float] = (0..<(32 * 32)).map { k in
                    spot(shape, (Float(k % 32) + 0.5) / 16 - 1, (Float(k / 32) + 0.5) / 16 - 1)
                }
                table.sort(by: totalLess)
                func cdf(_ x: Float) -> Float {
                    var lo = 0, hi = table.count
                    while lo < hi {
                        let mid = (lo + hi) / 2
                        if table[mid] < x { lo = mid + 1 } else { hi = mid }
                    }
                    return Float(lo) / Float(table.count)
                }
                let ww = max(w, 1)
                for i in gray.indices {
                    let (x, y) = (Float(i % ww) + 0.5, Float(i / ww) + 0.5)
                    let (rx, ry) = (x * c + y * s, -x * s + y * c)
                    let u = remEuclid1(rx / cell) * 2 - 1
                    let vv = remEuclid1(ry / cell) * 2 - 1
                    // Ink (black) covers where the spot function exceeds the gray level.
                    gray[i] = cdf(spot(shape, u, vv)) >= gray[i] ? 0 : 1
                }
            }
        }
    }
}
