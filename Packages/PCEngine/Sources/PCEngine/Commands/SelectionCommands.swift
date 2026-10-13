// Port of photocraft-engine (crates/engine/src/selection_cmds.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Select menu and selection tools: Magic Wand, Color Range, Modify (expand / contract / border /
// smooth / feather), Grow, Similar and Lasso. Selections are GRAY8 coverage surfaces clipped to
// the canvas. The algorithms are PCAlgo's `Selection` (photocraft-algo `selection`), run on the
// CPU (their reference path, photocraft's results).

import Foundation
import PCAlgo
import PCDocument
import PCFoundation
import PCPlatform

public enum SelectionCommands: CommandModule {
    public static let name = "selection_cmds"
    static let m = "selection_cmds"

    public static func register(into r: inout CommandRegistry) {
        r.add(CommandSpec("select.magicWand", "Magic Wand",
                          params: #"{"x":px,"y":px,"tolerance":0..255=32,"contiguous":bool=true,"antiAlias":bool=true,"sampleAllLayers":bool=false,"mode":"replace|add|subtract|intersect"="replace"} (samples the visible alpha, Quick Mask, or layer mask when that is the picture)"#,
                          module: m, enabled: Pre.hasDoc, run: magicWand))
        r.add(CommandSpec("select.colorRange", "Color Range…", menu: ["Select"],
                          params: ##"{"select":"sampledColors|reds|yellows|greens|cyans|blues|magentas|highlights|midtones|shadows|outOfGamut"="sampledColors","color":"#rrggbb"=foreground,"colors":["#rrggbb",…]?,"points":[[x,y],…]? (eyedropper samples),"subtractPoints":[[x,y],…]? (minus eyedropper),"order":["+"|"-",…]? (click order of points and subtractPoints; default all points first),"fuzziness":0..200=40 (tones: 0..100 %=20),"localized":bool=false,"range":0..100=100 (% of the longer side),"tonalRange":level|[lo,hi] (shadows 65, highlights 190, midtones [105,150]),"invert":bool=false,"sampleAllLayers":bool=true,"mode":"replace|add|subtract|intersect"="replace"}"##,
                          module: m, enabled: Pre.hasDoc, run: colorRange))
        r.add(CommandSpec("select.modify.border", "Border…", menu: ["Select", "Modify"], params: #"{"radius":1..200=1}"#,
                          module: m, enabled: hasSelection) { s, p in try modify(s, p, "border") })
        r.add(CommandSpec("select.modify.smooth", "Smooth…", menu: ["Select", "Modify"], params: #"{"radius":1..500=1,"applyAtCanvasBounds":bool=false}"#,
                          module: m, enabled: hasSelection) { s, p in try modify(s, p, "smooth") })
        r.add(CommandSpec("select.modify.expand", "Expand…", menu: ["Select", "Modify"], params: #"{"radius":1..500=1,"applyAtCanvasBounds":bool=false}"#,
                          module: m, enabled: hasSelection) { s, p in try modify(s, p, "expand") })
        r.add(CommandSpec("select.modify.contract", "Contract…", menu: ["Select", "Modify"], params: #"{"radius":1..500=1,"applyAtCanvasBounds":bool=false}"#,
                          module: m, enabled: hasSelection) { s, p in try modify(s, p, "contract") })
        r.add(CommandSpec("select.modify.feather", "Feather…", menu: ["Select", "Modify"], params: #"{"radius":0.1..1000=1,"applyAtCanvasBounds":bool=false}"#,
                          module: m, enabled: hasSelection) { s, p in try modify(s, p, "feather") })
        r.add(CommandSpec("select.grow", "Grow", menu: ["Select"], params: #"{"tolerance":0..255=32,"sampleAllLayers":bool=false}"#,
                          module: m, enabled: hasSelection) { s, p in try growSimilar(s, p, contiguous: true) })
        r.add(CommandSpec("select.similar", "Similar", menu: ["Select"], params: #"{"tolerance":0..255=32,"sampleAllLayers":bool=false}"#,
                          module: m, enabled: hasSelection) { s, p in try growSimilar(s, p, contiguous: false) })
        r.add(CommandSpec("select.lasso", "Lasso",
                          params: #"{"points":[[x,y],…],"mode":"replace|add|subtract|intersect"="replace","antiAlias":bool=true,"feather":px=0}"#,
                          module: m, enabled: Pre.hasDoc, run: lasso))
    }

    /// photocraft `has_selection` (no document reads as no selection).
    static let hasSelection: CommandEnabled = { s, _ in s.active?.doc.selection == nil ? "no selection" : nil }

    // MARK: Params

    /// photocraft `f`: a number param as Float, else `d`.
    static func f(_ p: JSONValue, _ k: String, _ d: Float) -> Float { p[k]?.doubleValue.map { Float($0) } ?? d }
    /// photocraft `b`: a bool param, else `d`.
    static func b(_ p: JSONValue, _ k: String, _ d: Bool) -> Bool { p[k]?.boolValue ?? d }
    /// photocraft `mode`: the selection mode (`replace` by default).
    static func mode(_ p: JSONValue) -> SelectionMath.Mode { SelectionMath.Mode.parse(p["mode"]?.stringValue ?? "replace") }

    /// A Float as Rust's saturating `as i32` (NaN → 0).
    static func i32(_ v: Float) -> Int32 {
        if v.isNaN { return 0 }
        if v >= 2_147_483_648 { return .max }
        if v <= -2_147_483_648 { return .min }
        return Int32(v)
    }

    /// PCAlgo's selection mode for `m`.
    static func algoMode(_ m: SelectionMath.Mode) -> PCAlgo.SelectionMode { PCAlgo.SelectionMode(rawValue: m.rawValue) ?? .replace }

    /// 8-bit straight RGBA of a composite pixel (photocraft `(v.clamp(0, 1) * 255 + 0.5) as u8`).
    @inline(__always)
    static func q8(_ p: SIMD4<Float>) -> SIMD4<UInt8> {
        func u8(_ v: Float) -> UInt8 { v.isNaN ? 0 : UInt8(min(max(v, 0), 1) * 255 + 0.5) }
        return SIMD4(u8(p.x), u8(p.y), u8(p.z), u8(p.w))
    }

    /// PCAlgo's `Selection.wandRegion`, nil when `img` does not cover `area` (never traps).
    static func wandRegion(_ img: [SIMD4<UInt8>], _ area: PixelRect, seed: (Int32, Int32), tolerance: Float, contiguous: Bool,
                           antiAlias: Bool) -> SelectionRegion? {
        guard img.count == area.area else { return nil }
        return Selection.wandRegion(img, area: area, seed: (x: seed.0, y: seed.1), tolerance: tolerance, contiguous: contiguous, antiAlias: antiAlias)
    }

    /// A Double as Rust's `Display` prints it (`30` for 30.0).
    static func num(_ d: Double) -> String {
        if d.isFinite, d == d.rounded(), abs(d) < 1e15 { return String(Int64(d)) }
        return "\(d)"
    }

    // MARK: Shared helpers

    /// A Color Range replacement is scoped to the selection that was active when it opened.
    static func pointInSelection(_ doc: Document, _ x: Int32, _ y: Int32) -> Bool {
        guard let sel = doc.selection else { return true }
        return sel.sampleChannel(x: x, y: y, 0) > 0
    }

    static func scopeColorRange(_ mask: inout [Float], _ doc: Document, _ area: PixelRect, _ m: SelectionMath.Mode) {
        guard m == .replace, let sel = doc.selection else { return }
        let prev = SelectionMath.mask(from: sel, area)
        for i in mask.indices where i < prev.count { mask[i] = min(mask[i], prev[i]) }
    }

    /// RGBA pixels the tools sample: the composite, or the active layer (photocraft
    /// `sample_pixels`).
    static func samplePixels(_ s: Session, allLayers: Bool) throws -> (PixelRect, [SIMD4<Float>]) {
        guard let d = s.active else { throw EngineError.noDocument }
        let area = d.doc.bounds
        if !allLayers, let surf = d.activeLayer.flatMap({ d.doc.layer($0) })?.surface {
            return (area, surf.readRGBA(area))
        }
        return (area, try s.services.renderer.render(d.doc, region: area).px)
    }

    /// 8-bit RGBA of the active layer (or the composite with `allLayers`) over the canvas
    /// (photocraft `sample_rgba8`).
    static func sampleRGBA8(_ s: Session, allLayers: Bool) throws -> (PixelRect, [SIMD4<UInt8>]) {
        guard let d = s.active else { throw EngineError.noDocument }
        let area = d.doc.bounds
        if !allLayers, let surf = d.activeLayer.flatMap({ d.doc.layer($0) })?.surface {
            return (area, Selection.rgba8Image(surf, area: area))
        }
        return (area, try s.services.renderer.render(d.doc, region: area).px.map(q8))
    }

    /// Replaces / combines the selection with `mask` over `area` as one step called `label`.
    @discardableResult
    static func setSelection(_ s: Session, _ label: String, _ area: PixelRect, _ mask: [Float], _ m: SelectionMath.Mode) throws -> JSONValue {
        var full = mask
        if full.count < area.area { full += [Float](repeating: 0, count: area.area - full.count) }
        let selected = try s.edit(label) { doc, _ -> Bool in
            doc.selection = SelectionMath.combine(doc.selection, full, area, m)
            return doc.selection != nil
        }
        return ["selected": .bool(selected)]
    }

    static func currentMask(_ doc: Document) -> (PixelRect, [Float]) {
        let area = doc.bounds
        return (area, SelectionMath.mask(from: doc.selection, area))
    }

    /// Grayscale the canvas is actually showing when that is not the colour composite: a gray
    /// layer-mask view, or — with every colour channel hidden — the first visible alpha, the
    /// Quick Mask, or the active layer's mask (photocraft `shown_gray`).
    static func shownGray(_ s: Session) -> (PixelRect, [SIMD4<UInt8>])? {
        guard let st = s.active else { return nil }
        let doc = st.doc, area = doc.bounds, v = st.channelView
        let colorsOff = v.visibleColors(Channels.colorCount(doc)) == 0
        let shown: (LayerMask, MaskViewMode)? = v.layerMask.flatMap { lm in doc.layer(lm.layer)?.mask.map { ($0, lm.mode) } }
        let surf: Surface
        if let (mask, mode) = shown, mode == .gray {
            surf = mask.surface
        } else if colorsOff {
            if let i = doc.channels.indices.first(where: { v.alphaShown($0) }) {
                surf = doc.channels[i].surface
            } else if let q = doc.quickMask, !v.quickMaskHidden {
                surf = q.surface
            } else if let (mask, _) = shown {
                surf = mask.surface
            } else if let m = st.activeLayer.flatMap({ doc.layer($0) })?.mask {
                surf = m.surface
            } else {
                return nil
            }
        } else {
            return nil
        }
        return (area, Selection.rgba8Image(surf, area: area))
    }

    // MARK: Magic Wand

    static func magicWand(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let x = i32(f(p, "x", 0).rounded(.down)), y = i32(f(p, "y", 0).rounded(.down))
        let (area, img) = try shownGray(s) ?? sampleRGBA8(s, allLayers: b(p, "sampleAllLayers", false))
        let region = wandRegion(img, area, seed: (x, y), tolerance: f(p, "tolerance", 32), contiguous: b(p, "contiguous", true),
                                antiAlias: b(p, "antiAlias", true))
        let m = algoMode(mode(p))
        let selected = try s.edit("Magic Wand") { doc, _ -> Bool in
            doc.selection = Selection.combineRegion(doc.selection, region, mode: m)
            return doc.selection != nil
        }
        return ["selected": .bool(selected)]
    }

    // MARK: Color Range

    /// photocraft `parse_color`: `[r,g,b]` floats or `"#rrggbb"` (missing digits read 0).
    static func parseColor(_ v: JSONValue?) -> SIMD3<Float> {
        switch v {
        case .array(let a)? where a.count >= 3:
            return SIMD3(Float(a[0].doubleValue ?? 0), Float(a[1].doubleValue ?? 0), Float(a[2].doubleValue ?? 0))
        case .string(let s)?:
            var h = Substring(s)
            while h.hasPrefix("#") { h = h.dropFirst() }
            let bytes = Array(h.utf8)
            func c(_ i: Int) -> Float {
                guard i + 2 <= bytes.count, let v = UInt8(String(decoding: bytes[i..<i + 2], as: UTF8.self), radix: 16) else { return 0 }
                return Float(v) / 255
            }
            return SIMD3(c(0), c(2), c(4))
        default:
            return .zero
        }
    }

    /// The `[[x, y], …]` points of `key` (finite numbers), as photocraft reads them.
    static func points(_ p: JSONValue, _ key: String, bad: (String) -> EngineError) throws -> [(Double, Double)]? {
        guard let v = p[key] else { return nil }
        guard let pts = v.arrayValue else { throw bad("`\(key)` must be [[x, y], …]") }
        return try pts.map { pt in
            guard let a = pt.arrayValue, a.count == 2, let x = a[0].doubleValue, let y = a[1].doubleValue, x.isFinite, y.isFinite else {
                throw bad("bad point \(pt.serialized()) in `\(key)` (want [x, y])")
            }
            return (x, y)
        }
    }

    /// Eyedropper samples from `key` over the sampled pixels (photocraft `eyedropper_samples`).
    static func eyedropperSamples(_ p: JSONValue, _ key: String, _ area: PixelRect, _ px: [SIMD4<Float>],
                                  allowed: (Int32, Int32) -> Bool, bad: (String) -> EngineError) throws -> [RangeSample] {
        guard let pts = try points(p, key, bad: bad) else { return [] }
        let w = area.width
        var out: [RangeSample] = []
        for (x, y) in pts {
            let xi = i32(Float(x).rounded(.down)), yi = i32(Float(y).rounded(.down))
            var q: SIMD4<Float>?
            if area.contains(x: xi, y: yi) {
                let i = Int(yi - area.y0) * w + Int(xi - area.x0)
                if i < px.count { q = px[i] }
            }
            guard let c = q else { throw bad("point [\(num(x)), \(num(y))] in `\(key)` is outside the canvas") }
            if !allowed(xi, yi) { throw bad("point [\(num(x)), \(num(y))] in `\(key)` is outside the active selection") }
            out.append(RangeSample(color: SIMD3(c.x, c.y, c.z), at: SIMD2(Float(xi - area.x0), Float(yi - area.y0))))
        }
        return out
    }

    /// The composite's profile as RGB (photocraft `color_cmds::composite_profile`): the
    /// document's own RGB profile, else sRGB.
    static func compositeProfile(_ doc: Document) -> ICCProfile {
        if doc.mode == .rgb, let bytes = doc.iccProfile, let p = try? ICCProfile(data: Data(bytes)), p.colorSpace == .rgb {
            return p
        }
        return BuiltinProfile.srgb.profile
    }

    /// Composite RGB → CIE Lab D50 (photocraft `lab_transform`).
    static func labTransform(_ doc: Document) throws -> ColorTransform {
        do {
            return try ColorTransform.cached(source: compositeProfile(doc), destination: BuiltinProfile.labD50.profile, options: TransformOptions())
        } catch {
            throw EngineError.other("colour management: \(error)")
        }
    }

    static func colourToLab(_ t: ColorTransform, _ rgb: SIMD3<Float>) -> SIMD3<Float> {
        let c = rgb.clamped(lowerBound: .zero, upperBound: .one)
        let o = t.eval([c.x, c.y, c.z])
        guard o.count >= 3 else { return .zero }
        let l = LabEncoding.colorSync.decode(SIMD3(o[0], o[1], o[2]))
        return SIMD3(Float(l.x), Float(l.y), Float(l.z))
    }

    /// RGBA pixels → Lab + alpha (L, a, b, alpha).
    static func pixelsToLab(_ t: ColorTransform, _ px: [SIMD4<Float>]) -> [SIMD4<Float>] {
        if px.isEmpty { return [] }
        var src = [Float](repeating: 0, count: px.count * 4)
        for (i, p) in px.enumerated() {
            src[i * 4] = min(max(p.x, 0), 1); src[i * 4 + 1] = min(max(p.y, 0), 1); src[i * 4 + 2] = min(max(p.z, 0), 1); src[i * 4 + 3] = p.w
        }
        let out = t.convert(src, pixelCount: px.count, alpha: true)
        guard out.count >= px.count * 4 else { return [SIMD4<Float>](repeating: .zero, count: px.count) }
        return (0..<px.count).map { i in
            let l = LabEncoding.colorSync.decode(SIMD3(out[i * 4], out[i * 4 + 1], out[i * 4 + 2]))
            return SIMD4(Float(l.x), Float(l.y), Float(l.z), out[i * 4 + 3])
        }
    }

    /// The prepared Sampled Colors query shared by the command and its interactive preview
    /// (photocraft `ColorRangeSamples`). Samples always come from the original document.
    public struct ColorRangeSamples: Sendable {
        let toLab: ColorTransform
        public let range: LabRange
        let grid: Bool
        let fuzziness: Float
        let localized: Float?
        let plusAt: [SIMD2<Float>]

        /// Prepares the query for `p` on the session's active document (point samples read one
        /// composite or layer pixel each).
        public init(_ s: Session, _ p: JSONValue) throws {
            guard let d = s.active else { throw EngineError.noDocument }
            let doc = d.doc, area = doc.bounds
            let bad = { (msg: String) in EngineError.bad("select.colorRange", msg) }
            let m = SelectionCommands.mode(p)
            func sample(_ key: String) throws -> [RangeSample] {
                guard let pts = try SelectionCommands.points(p, key, bad: bad) else { return [] }
                var out: [RangeSample] = []
                for (xf, yf) in pts {
                    let x = i32(Float(xf).rounded(.down)), y = i32(Float(yf).rounded(.down))
                    if !area.contains(x: x, y: y) { throw bad("point [\(x), \(y)] in `\(key)` is outside the canvas") }
                    if m == .replace && !pointInSelection(doc, x, y) { throw bad("point [\(x), \(y)] in `\(key)` is outside the active selection") }
                    let r = PixelRect(x0: x, y0: y, x1: x + 1, y1: y + 1)
                    var px: SIMD4<Float>?
                    if !SelectionCommands.b(p, "sampleAllLayers", true), let surf = d.activeLayer.flatMap({ doc.layer($0) })?.surface {
                        px = surf.readRGBA(r).first
                    }
                    let c = try px ?? (s.services.renderer.render(doc, region: r).px.first ?? .zero)
                    out.append(RangeSample(color: SIMD3(c.x, c.y, c.z), at: SIMD2(Float(x - area.x0), Float(y - area.y0))))
                }
                return out
            }
            try self.init(s, p, area, plus: sample("points"), minus: sample("subtractPoints"))
        }

        init(_ s: Session, _ p: JSONValue, _ area: PixelRect, plus: [RangeSample], minus: [RangeSample]) throws {
            let bad = { (msg: String) in EngineError.bad("select.colorRange", msg) }
            let fuzz = Float.maximum(SelectionCommands.f(p, "fuzziness", 40), 0)
            // The order the eyedropper clicks came in ("+" a point, "-" a subtracted point).
            var order: [Bool]
            if let o = p["order"] {
                guard let arr = o.arrayValue else { throw bad("`order` must be a list of \"+\" and \"-\"") }
                order = try arr.map { v in
                    switch v.stringValue {
                    case "+"?: return true
                    case "-"?: return false
                    default: throw bad("bad entry \(v.serialized()) in `order` (want \"+\" or \"-\")")
                    }
                }
                if order.filter({ $0 }).count != plus.count || order.filter({ !$0 }).count != minus.count {
                    throw bad("`order` must list each of `points` (\"+\") and `subtractPoints` (\"-\") once")
                }
            } else {
                order = [Bool](repeating: true, count: plus.count) + [Bool](repeating: false, count: minus.count)
            }
            var fixed: [SIMD3<Float>] = []
            if let cs = p["colors"] {
                guard let arr = cs.arrayValue else { throw bad("`colors` must be a list of colours") }
                fixed += arr.map { SelectionCommands.parseColor($0) }
            }
            if let c = p["color"] { fixed.append(SelectionCommands.parseColor(c)) }
            // Localized Color Clusters: Range is a percentage of the canvas's longer side.
            let plusAt = plus.compactMap(\.at)
            var localized: Float?
            if SelectionCommands.b(p, "localized", false) {
                if plusAt.isEmpty { throw bad("localized clusters need eyedropper `points`") }
                localized = min(max(SelectionCommands.f(p, "range", 100), 0), 100) / 100 * Float(max(area.width, area.height))
            }
            guard let d = s.active else { throw EngineError.noDocument }
            let toLab = try labTransform(d.doc)
            // 8-bit documents are compared on the 8-bit Lab grid, samples and pixels alike.
            let grid = d.doc.depth == .u8
            func lab(_ c: SIMD3<Float>) -> SIMD3<Float> {
                let v = colourToLab(toLab, c)
                return grid ? Selection.quantizeLab8(v) : v
            }
            let fg = s.tools.foreground
            func foreground() -> LabRange { .point(lab(SIMD3(fg.x, fg.y, fg.z))) }
            var range = LabRange.spanning(fixed.map(lab))
            var pi = plus.makeIterator(), mi = minus.makeIterator()
            for add in order {
                if add {
                    if let x = pi.next() {
                        let c = lab(x.color)
                        range = range.map { $0.grow(c) } ?? .point(c)
                    }
                } else if let x = mi.next() {
                    range = (range ?? foreground()).subtract(lab(x.color), fuzziness: fuzz)
                }
            }
            self.toLab = toLab
            self.range = range ?? foreground()
            self.grid = grid
            self.fuzziness = fuzz
            self.localized = localized
            self.plusAt = plusAt
        }

        /// Coverage of a composite rectangle. `scale` is the original document pixels one input
        /// pixel stands for; `origin` is in original document pixels (a visible canvas crop).
        public func coverage(_ px: [SIMD4<Float>], width: Int, scale: Float = 1, origin: SIMD2<Float> = .zero) -> [Float] {
            var lab = pixelsToLab(toLab, px)
            if grid {
                for i in lab.indices {
                    let q = Selection.quantizeLab8(SIMD3(lab[i].x, lab[i].y, lab[i].z))
                    lab[i] = SIMD4(q, lab[i].w)
                }
            }
            let sc: Float = scale.isFinite && scale > 0 ? scale : 1
            let pts = plusAt.map { ($0 - origin) / sc }
            let loc: (radius: Float, at: [SIMD2<Float>])? = localized.map { (radius: $0 / sc, at: pts) }
            // The CPU reference never throws (only a GPU request can).
            return (try? Selection.colorRangeLab(lab, w: width, range: range, fuzziness: fuzziness, grid8: grid, localized: loc, on: .cpu))
                ?? [Float](repeating: 0, count: lab.count)
        }
    }

    static func colorRange(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "select.colorRange"
        let bad = { (msg: String) in EngineError.bad(cmd, msg) }
        var preset = "sampledColors"
        if let v = p["select"] {
            guard let str = v.stringValue else { throw bad("`select` must be a string") }
            preset = str
        }
        let invert = b(p, "invert", false)
        let selMode = mode(p)
        let fuzz = { (d: Float) in Float.maximum(f(p, "fuzziness", d), 0) }
        var area: PixelRect
        var mask: [Float]
        switch preset {
        case "sampledColors":
            let (a, px) = try samplePixels(s, allLayers: b(p, "sampleAllLayers", true))
            guard let doc = s.active?.doc else { throw EngineError.noDocument }
            let allowed = { (x: Int32, y: Int32) in selMode != .replace || pointInSelection(doc, x, y) }
            let plus = try eyedropperSamples(p, "points", a, px, allowed: allowed, bad: bad)
            let minus = try eyedropperSamples(p, "subtractPoints", a, px, allowed: allowed, bad: bad)
            let query = try ColorRangeSamples(s, p, a, plus: plus, minus: minus)
            area = a
            mask = query.coverage(px, width: a.width)
        case "reds", "yellows", "greens", "cyans", "blues", "magentas":
            let center: Float = ["reds": 0, "yellows": 60, "greens": 120, "cyans": 180, "blues": 240][preset] ?? 300
            let (a, px) = try samplePixels(s, allLayers: b(p, "sampleAllLayers", true))
            area = a
            mask = try Selection.hueRange(px, center: center, on: .cpu)
        case "highlights", "midtones", "shadows":
            // Range in levels (Highlights / Shadows one value, Midtones [low, high]); Fuzziness is
            // a percentage of the tonal scale.
            func level(_ v: JSONValue) -> Float? {
                guard let x = v.doubleValue, x >= 0, x <= 255 else { return nil }
                return Float(x)
            }
            let lo: Float, hi: Float
            switch (preset, p["tonalRange"]) {
            case ("shadows", nil): (lo, hi) = (0, 65)
            case ("highlights", nil): (lo, hi) = (190, 255)
            case (_, nil): (lo, hi) = (105, 150)
            case ("shadows", let v?):
                guard let l = level(v) else { throw bad("tonalRange: want a level 0..255 (got \(v.serialized()))") }
                (lo, hi) = (0, l)
            case ("highlights", let v?):
                guard let l = level(v) else { throw bad("tonalRange: want a level 0..255 (got \(v.serialized()))") }
                (lo, hi) = (l, 255)
            case (_, let v?):
                guard let a = v.arrayValue, a.count == 2, let l = level(a[0]), let h = level(a[1]), l <= h else {
                    throw bad("tonalRange: want [low, high] levels 0..255 (got \(v.serialized()))")
                }
                (lo, hi) = (l, h)
            }
            let (a, px) = try samplePixels(s, allLayers: b(p, "sampleAllLayers", true))
            area = a
            mask = try Selection.toneRange(px, lo: lo, hi: hi, falloff: min(fuzz(20), 100) / 100 * 255, on: .cpu)
        case "outOfGamut":
            // Pixels the proof setup can't reproduce, judged on the composite as the gamut warning
            // shows them. The proof is Photoshop's default (Working CMYK, ΔE threshold 4).
            guard let d = s.active else { throw EngineError.noDocument }
            area = d.doc.bounds
            mask = try outOfGamutMask(s, d.doc)
        default:
            throw bad("unknown select `\(preset)` (sampledColors, reds, yellows, greens, cyans, blues, magentas, highlights, midtones, shadows, outOfGamut)")
        }
        if invert { for i in mask.indices { mask[i] = 1 - mask[i] } }
        // Invert the colour result first, then constrain it to the original selection.
        guard let doc = s.active?.doc else { throw EngineError.noDocument }
        scopeColorRange(&mask, doc, area, selMode)
        return try setSelection(s, "Color Range", area, mask, selMode)
    }

    /// The gamut warning's mask of the composite (photocraft `color_cmds::gamut_mask`), against
    /// the default proof (Working CMYK).
    static func outOfGamutMask(_ s: Session, _ doc: Document) throws -> [Float] {
        let check: GamutCheck
        do {
            check = try GamutCheck(source: compositeProfile(doc), proof: BuiltinProfile.defaultProfile(for: .cmyk))
        } catch {
            throw EngineError.other("colour management: \(error)")
        }
        let px = try s.services.renderer.render(doc, region: doc.bounds).px
        return px.map { p in p.w > 0 && check.isOutOfGamut([p.x, p.y, p.z]) ? 1 : 0 }
    }

    // MARK: Modify

    /// The largest padded mask Modify works on.
    static let maxModifyPixels = 1 << 30

    static func modify(_ s: Session, _ p: JSONValue, _ op: String) throws -> JSONValue {
        let cmd = "select.modify.\(op)"
        // The dialogs' ranges (Photoshop's limits); anything else is refused, never clamped.
        let (lo, hi, range): (Float, Float, String) = switch op {
        case "border": (1, 200, "1..200")
        case "feather": (0.1, 1000, "0.1..1000")
        default: (1, 500, "1..500")
        }
        let r = f(p, "radius", 1)
        guard r >= lo && r <= hi else { throw EngineError.bad(cmd, "radius must be a number in \(range)") }
        // Photoshop's "Apply effect at canvas bounds"; Border always follows the canvas edge.
        let atBounds = op == "border" || b(p, "applyAtCanvasBounds", false)
        guard let doc = s.active?.doc else { throw EngineError.noDocument }
        let (area, m) = currentMask(doc)
        let w = area.width, h = area.height
        // Feather reaches 3σ = 3 r; the others reach r. A margin past that keeps the canvas edge
        // out of reach; a selection clear of the edge needs none.
        let reach = op == "feather" ? r * 3 : r
        let pad = touchesEdge(m, w, h) ? Int(reach.rounded(.up)) + 2 : 0
        let (pw, o1) = w.addingReportingOverflow(pad * 2), (ph, o2) = h.addingReportingOverflow(pad * 2)
        let (n, o3) = pw.multipliedReportingOverflow(by: ph)
        if o1 || o2 || o3 || n > maxModifyPixels { throw EngineError.bad(cmd, "the selection is too large to modify") }
        let padded = pad == 0 ? m : padMask(m, w, h, pad, outsideEmpty: atBounds)
        var out: [Float]
        switch op {
        case "expand": out = try Selection.expand(padded, w: pw, h: ph, r: r, on: .cpu)
        case "contract": out = try Selection.contract(padded, w: pw, h: ph, r: r, on: .cpu)
        case "border": out = try Selection.border(padded, w: pw, h: ph, r: r, on: .cpu)
        case "smooth": out = try Selection.smooth(padded, w: pw, h: ph, r: r, on: .cpu)
        default: out = try Selection.feather(padded, w: pw, h: ph, radius: r, on: .cpu)
        }
        if pad != 0 { out = cropMask(out, pw, pad, w, h) }
        let label = switch op {
        case "expand": "Expand Selection"
        case "contract": "Contract Selection"
        case "border": "Border Selection"
        case "smooth": "Smooth Selection"
        default: "Feather Selection"
        }
        return try setSelection(s, label, area, out, .replace)
    }

    /// Whether any pixel on the outermost rows or columns of `m` (`w`×`h`) is selected.
    static func touchesEdge(_ m: [Float], _ w: Int, _ h: Int) -> Bool {
        func sel(_ x: Int, _ y: Int) -> Bool {
            let i = y * w + x
            return i >= 0 && i < m.count && m[i] > 0
        }
        if w == 0 || h == 0 { return false }
        for x in 0..<w where sel(x, 0) || sel(x, h - 1) { return true }
        for y in 0..<h where sel(0, y) || sel(w - 1, y) { return true }
        return false
    }

    /// `m` (`w`×`h`) with a `pad`-pixel margin: unselected when `outsideEmpty`, else the nearest
    /// edge pixel repeated (photocraft `pad_mask`).
    static func padMask(_ m: [Float], _ w: Int, _ h: Int, _ pad: Int, outsideEmpty: Bool) -> [Float] {
        let pw = w + 2 * pad, ph = h + 2 * pad
        var out = [Float](repeating: 0, count: pw * ph)
        if w == 0 || h == 0 || m.count < w * h { return out }
        for py in 0..<ph {
            if outsideEmpty && !(py >= pad && py < pad + h) { continue }
            let y = min(max(py - pad, 0), h - 1)
            let row = py * pw
            for x in 0..<w { out[row + pad + x] = m[y * w + x] }
            if !outsideEmpty {
                let first = m[y * w], last = m[y * w + w - 1]
                for x in 0..<pad { out[row + x] = first; out[row + pad + w + x] = last }
            }
        }
        return out
    }

    /// The `w`×`h` centre of a mask padded by `padMask`.
    static func cropMask(_ m: [Float], _ pw: Int, _ pad: Int, _ w: Int, _ h: Int) -> [Float] {
        var out: [Float] = []
        out.reserveCapacity(w * h)
        for y in 0..<h {
            let o = (y + pad) * pw + pad
            if o + w <= m.count { out += m[o..<o + w] } else { out += [Float](repeating: 0, count: w) }
        }
        return out
    }

    // MARK: Grow / Similar

    /// Grow (contiguous) / Similar (anywhere): pixels whose colour lies within the selected
    /// pixels' colour range widened by the tolerance.
    static func growSimilar(_ s: Session, _ p: JSONValue, contiguous: Bool) throws -> JSONValue {
        let tol = f(p, "tolerance", 32) / 255
        let (area, px) = try samplePixels(s, allLayers: b(p, "sampleAllLayers", false))
        guard let doc = s.active?.doc else { throw EngineError.noDocument }
        let (_, m) = currentMask(doc)
        var lo = SIMD4<Float>(repeating: .greatestFiniteMagnitude), hi = SIMD4<Float>(repeating: -.greatestFiniteMagnitude)
        for (q, v) in zip(px, m) where v >= 0.5 {
            lo = pointwiseMin(lo, q)
            hi = pointwiseMax(hi, q)
        }
        if lo.x > hi.x { throw EngineError.other("selection is empty") }
        func inside(_ q: SIMD4<Float>) -> Bool {
            for c in 0..<4 where !(q[c] >= lo[c] - tol - 1e-6 && q[c] <= hi[c] + tol + 1e-6) { return false }
            return true
        }
        let w = area.width, h = area.height
        var out = m.map { $0 >= 0.5 ? Float(1) : 0 }
        if out.count < px.count { out += [Float](repeating: 0, count: px.count - out.count) }
        if contiguous {
            var stack = out.indices.filter { out[$0] > 0 }
            while let i = stack.popLast() {
                let x = i % w, y = i / w
                for j in [x > 0 ? i - 1 : -1, x + 1 < w ? i + 1 : -1, y > 0 ? i - w : -1, y + 1 < h ? i + w : -1] where j >= 0 {
                    if out[j] == 0 && inside(px[j]) {
                        out[j] = 1
                        stack.append(j)
                    }
                }
            }
        } else {
            for i in out.indices where i < px.count && inside(px[i]) { out[i] = 1 }
        }
        return try setSelection(s, contiguous ? "Grow" : "Similar", area, out, .replace)
    }

    // MARK: Lasso

    static func lasso(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let pts: [SIMD2<Float>] = (p["points"]?.arrayValue ?? []).compactMap { q in
            guard let a = q.arrayValue, a.count >= 2, let x = a[0].doubleValue, let y = a[1].doubleValue else { return nil }
            return SIMD2(Float(x), Float(y))
        }
        if pts.count < 3 { throw EngineError.bad("select.lasso", "needs at least 3 points") }
        return try polygonSelection(s, "select.lasso", "Lasso", pts, p)
    }

    /// Selects the polygon `pts` with the lasso tools' `mode`, `antiAlias` and `feather` params,
    /// as one history step called `label` (photocraft `polygon_selection`).
    static func polygonSelection(_ s: Session, _ cmd: String, _ label: String, _ pts: [SIMD2<Float>], _ p: JSONValue) throws -> JSONValue {
        let feather = f(p, "feather", 0)
        // Select › Modify › Feather's range.
        guard feather >= 0 && feather <= 1000 else { throw EngineError.bad(cmd, "feather must be a number in 0..1000") }
        guard let area = s.active?.doc.bounds else { throw EngineError.noDocument }
        var mask = Selection.polygon(pts, area: area, antiAlias: b(p, "antiAlias", true))
        if feather > 0 { mask = try Selection.feather(mask, w: area.width, h: area.height, radius: feather, on: .cpu) }
        return try setSelection(s, label, area, mask, mode(p))
    }
}
