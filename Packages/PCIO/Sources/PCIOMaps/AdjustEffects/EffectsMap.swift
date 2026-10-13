// Layer effects ⇄ PSD `lfx2` (object-based effects descriptor; also `lfxs` on groups and `lmfx`)
// and legacy `lrFX`.
// Port of photocraft-io (crates/io/src/effects_map.rs; the blend-mode ID tables live in PCIOCore's
// `Blocks`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Key names follow the descriptors Photoshop writes (documented by reverse-engineering in
// MIT-licensed psd-tools / ag-psd).

import Foundation
import PCDocument
import PCFoundation
import PCIOCore
import PCPSD

public enum EffectsMap {
    /// Single-instance key and multi-instance list key for each kind, in Photoshop's order.
    static let kinds: [(single: String, multi: String)] = [
        ("DrSh", "dropShadowMulti"),
        ("IrSh", "innerShadowMulti"),
        ("OrGl", ""),
        ("IrGl", ""),
        ("ebbl", ""),
        ("ChFX", ""),
        ("SoFi", "solidFillMulti"),
        ("GrFl", "gradientFillMulti"),
        ("patternFill", ""),
        ("FrFX", "frameFXMulti"),
    ]

    /// Parses `lfx2` block data (also `lfxs` / `lmfx`): (master switch, effects).
    public static func parseLfx2(_ data: [UInt8]) -> (enabled: Bool, items: [Effect])? {
        guard data.count >= 4, let d = Blocks.parsePrefixVersioned(data, from: 4) else { return nil }
        var master = true
        if case .boolean(false)? = d["masterFXSwitch"] { master = false }
        var out: [Effect] = []
        for (single, multi) in kinds {
            if !multi.isEmpty, case let .list(items)? = d[multi] {
                for it in items {
                    if case let .descriptor(x) = it, let e = parseOne(single, x) { out.append(e) }
                }
            } else if let x = Blocks.getDesc(d, single), let e = parseOne(single, x) {
                out.append(e)
            }
        }
        return (master, out)
    }

    /// Serializes effects as `lfx2` block data.
    public static func writeLfx2(_ master: Bool, _ items: [Effect]) -> [UInt8] {
        var d = PSDDescriptor(classID: "null").with("Scl ", unit("#Prc", 100)).with("masterFXSwitch", .boolean(master))
        let written = items.map(writeOne)
        for (single, multi) in kinds {
            let ofKind = written.filter { $0.key == single }.map(\.descriptor)
            switch ofKind.count {
            case 0: break
            case 1: d = d.with(single, .descriptor(ofKind[0]))
            default:
                if !multi.isEmpty {
                    d = d.with(multi, .list(ofKind.map { .descriptor($0) }))
                } else {
                    // Kinds without a multi key keep only the first instance.
                    d = d.with(single, .descriptor(ofKind[0]))
                }
            }
        }
        return [0, 0, 0, 0] + Blocks.versionedBytes(d)
    }

    /// Parses legacy `lrFX` effects (Photoshop 5 layout): drop/inner shadows, outer/inner glows and
    /// solid fill. Bevels are skipped.
    public static func parseLrfx(_ data: [UInt8]) -> (enabled: Bool, items: [Effect])? {
        func be16(_ at: Int) -> UInt16? {
            guard at >= 0, at <= data.count - 2 else { return nil }
            return UInt16(data[at]) << 8 | UInt16(data[at + 1])
        }
        func be32(_ at: Int) -> UInt32? {
            guard at >= 0, at <= data.count - 4 else { return nil }
            return UInt32(data[at]) << 24 | UInt32(data[at + 1]) << 16 | UInt32(data[at + 2]) << 8 | UInt32(data[at + 3])
        }
        func byte(_ at: Int) -> UInt8? { at >= 0 && at < data.count ? data[at] : nil }
        func slice(_ at: Int, _ n: Int) -> [UInt8]? {
            guard at >= 0, n >= 0, at <= data.count - n else { return nil }
            return Array(data[at ..< at + n])
        }
        func colorAt(_ at: Int) -> PCColor? {
            // space (2) + 4 × u16 components (RGB uses the first three).
            func c(_ k: Int) -> Float? { be16(at + 2 + k * 2).map { Float($0 >> 8) / 255 } }
            guard let r = c(0), let g = c(1), let b = c(2) else { return nil }
            return .rgb(r, g, b)
        }
        func blendAt(_ at: Int) -> BlendMode {
            slice(at + 4, 4).flatMap { BlendMode(psdKey: String(decoding: $0, as: UTF8.self)) } ?? .normal
        }
        func fixed(_ v: UInt32) -> Float { Float(Int32(bitPattern: v)) / 65536 }

        guard let count = be16(2) else { return nil }
        var at = 4
        var out: [Effect] = []
        for _ in 0 ..< Int(count) {
            guard let sig = slice(at, 4), sig == Array("8BIM".utf8) else { return nil }
            guard let keyBytes = slice(at + 4, 4), let size32 = be32(at + 8) else { return nil }
            let key = FourCC(bytes: keyBytes)
            let size = Int(size32)
            let b = at + 12 // start of this effect's data (after the size field)
            switch key {
            case "dsdw", "isdw":
                // Blur, angle and distance are 16.16 fixed point in practice.
                guard let blurRaw = be32(b + 4), let angleRaw = be32(b + 12), let distRaw = be32(b + 16), let color = colorAt(b + 20) else { return nil }
                let blend = blendAt(b + 30)
                guard let en = byte(b + 38), let ug = byte(b + 39), let op = byte(b + 40) else { return nil }
                let s = Shadow(common: FxCommon(enabled: en != 0, blend: blend, opacity: Float(op) / 255), color: color, angle: fixed(angleRaw),
                               useGlobalLight: ug != 0, distance: fixed(distRaw), spread: 0, size: fixed(blurRaw), contour: .linear, antiAlias: false,
                               noise: 0, knocksOut: key == "dsdw")
                out.append(key == "dsdw" ? .dropShadow(s) : .innerShadow(s))
            case "oglw", "iglw":
                guard let blurRaw = be32(b + 4), let color = colorAt(b + 12) else { return nil }
                let blend = blendAt(b + 22)
                guard let en = byte(b + 30), let op = byte(b + 31) else { return nil }
                let g = Glow(common: FxCommon(enabled: en != 0, blend: blend, opacity: Float(op) / 255), paint: .color(color), technique: .softer,
                             spread: 0, size: fixed(blurRaw), contour: .linear, antiAlias: false, range: 0.5, jitter: 0, noise: 0, source: .edge)
                out.append(key == "oglw" ? .outerGlow(g) : .innerGlow(g))
            case "sofi":
                let blend = blendAt(b + 4)
                guard let color = colorAt(b + 12), let op = byte(b + 22), let en = byte(b + 23) else { return nil }
                out.append(.colorOverlay(Effect.ColorOverlay(common: FxCommon(enabled: en != 0, blend: blend, opacity: Float(op) / 255), color: color)))
            default:
                break
            }
            at = b &+ size
        }
        return (true, out)
    }
}

// MARK: - Reading

extension EffectsMap {
    private static func blendOf(_ d: PSDDescriptor, _ key: String, _ def: BlendMode) -> BlendMode {
        Blocks.enumOf(d, key).flatMap(Blocks.blendFromId) ?? def
    }

    private static func f(_ d: PSDDescriptor, _ key: String, _ def: Float) -> Float {
        Blocks.num(d[key]).map { Float($0) } ?? def
    }

    private static func pct(_ d: PSDDescriptor, _ key: String, _ def: Float) -> Float {
        f(d, key, def * 100) / 100
    }

    private static func color(_ d: PSDDescriptor, _ key: String) -> PCColor {
        Blocks.getDesc(d, key).flatMap(Blocks.colorFromDesc) ?? .black
    }

    private static func notFalse(_ d: PSDDescriptor, _ key: String) -> Bool {
        if case .boolean(false)? = d[key] { return false }
        return true
    }

    private static func contour(_ d: PSDDescriptor, _ key: String) -> Contour {
        guard let c = Blocks.getDesc(d, key) else { return .linear }
        var name = ""
        if case let .text(t)? = c["Nm  "] { name = t.string }
        var points: [CurvePoint] = []
        var corners: [Bool] = []
        if case let .list(items)? = c["Crv "] {
            for it in items {
                guard case let .descriptor(p) = it else { continue }
                points.append(CurvePoint(input: f(p, "Hrzn", 0) / 255, output: f(p, "Vrtc", 0) / 255))
                // `Cnty` (continuity): false marks a corner point; absent means smooth.
                if case .boolean(false)? = p["Cnty"] { corners.append(true) } else { corners.append(false) }
            }
        }
        if !corners.contains(true) { corners = [] }
        let linear = points.count == 2 && points[0].input == 0 && points[0].output == 0 && points[1].input == 1 && points[1].output == 1
        if points.isEmpty || (linear && (name.isEmpty || name == "Linear")) { return .linear }
        return .custom(Contour.CustomContour(name: name, points: points, corners: corners))
    }

    private static func common(_ d: PSDDescriptor, _ blend: BlendMode, _ opacity: Float) -> FxCommon {
        FxCommon(enabled: notFalse(d, "enab"), blend: blendOf(d, "Md  ", blend), opacity: pct(d, "Opct", opacity))
    }

    private static func gradientFrom(_ d: PSDDescriptor) -> StyleGradient {
        let parsed = Blocks.getDesc(d, "Grad").map { Blocks.gradientStopsWith($0, Blocks.gradientMethod(d)) }
        let stops = parsed?.stops ?? [], opacityStops = parsed?.opacity ?? []
        let off = Blocks.getDesc(d, "Ofst")
        return StyleGradient(stops: stops.isEmpty ? StyleGradient().stops : stops,
                             opacityStops: opacityStops,
                             style: Blocks.gradientStyle(d),
                             angle: f(d, "Angl", 90),
                             scale: pct(d, "Scl ", 1),
                             reverse: Blocks.boolOf(d, "Rvrs"),
                             align: notFalse(d, "Algn"),
                             offset: off.map { SIMD2(pct($0, "Hrzn", 0), pct($0, "Vrtc", 0)) } ?? .zero)
    }

    private static func parseShadow(_ d: PSDDescriptor, _ inner: Bool) -> Shadow {
        Shadow(common: common(d, .multiply, 0.75),
               color: color(d, "Clr "),
               angle: f(d, "lagl", 120),
               useGlobalLight: notFalse(d, "uglg"),
               distance: f(d, "Dstn", 5),
               spread: pct(d, "Ckmt", 0),
               size: f(d, "blur", 5),
               contour: contour(d, "TrnS"),
               antiAlias: Blocks.boolOf(d, "AntA"),
               noise: pct(d, "Nose", 0),
               knocksOut: !inner && notFalse(d, "layerConceals"))
    }

    private static func parseGlow(_ d: PSDDescriptor, _ inner: Bool) -> Glow {
        let paint: FxPaint = d["Grad"] != nil ? .gradient(gradientFrom(d)) : .color(color(d, "Clr "))
        return Glow(common: common(d, .screen, 0.75),
                    paint: paint,
                    technique: Blocks.enumOf(d, "GlwT") == "PrBL" ? .precise : .softer,
                    spread: pct(d, "Ckmt", 0),
                    size: f(d, "blur", 5),
                    contour: contour(d, "TrnS"),
                    antiAlias: Blocks.boolOf(d, "AntA"),
                    range: pct(d, "Inpr", 0.5),
                    jitter: pct(d, "ShdN", 0),
                    noise: pct(d, "Nose", 0),
                    source: inner && Blocks.enumOf(d, "glwS") == "SrcC" ? .center : .edge)
    }

    private static func parseStroke(_ d: PSDDescriptor) -> StrokeFx {
        let paint: FxPaint
        switch Blocks.enumOf(d, "PntT") {
        case "GrFl": paint = .gradient(gradientFrom(d))
        case "Ptrn":
            let p = Blocks.getDesc(d, "Ptrn")
            func text(_ k: String) -> String {
                if case let .text(t)? = p?[k] { return t.string }
                return ""
            }
            paint = .pattern(FxPaint.PatternRef(name: text("Nm  "), id: text("Idnt"), scale: pct(d, "Scl ", 1)))
        default: paint = .color(color(d, "Clr "))
        }
        let position: StrokePosition
        switch Blocks.enumOf(d, "Styl") {
        case "InsF": position = .inside
        case "CtrF": position = .center
        default: position = .outside
        }
        return StrokeFx(common: common(d, .normal, 1), size: f(d, "Sz  ", 3), position: position, paint: paint)
    }

    private static func parseBevel(_ d: PSDDescriptor) -> Bevel {
        let style: BevelStyle
        switch Blocks.enumOf(d, "bvlS") {
        case "OtrB": style = .outerBevel
        case "Embs": style = .emboss
        case "PlEb": style = .pillowEmboss
        case "strokeEmboss": style = .strokeEmboss
        default: style = .innerBevel
        }
        let technique: BevelTechnique
        switch Blocks.enumOf(d, "bvlT") {
        case "PrBL": technique = .chiselHard
        case "Slmt": technique = .chiselSoft
        default: technique = .smooth
        }
        var contour: BevelContour?
        if Blocks.boolOf(d, "useShape") {
            contour = BevelContour(contour: self.contour(d, "MpgS"), range: pct(d, "Inpr", 0.5), antiAlias: Blocks.boolOf(d, "AntA"))
        }
        var texture: BevelTexture?
        if Blocks.boolOf(d, "useTexture") {
            let (name, id) = Blocks.patternRef(d)
            let (_, link, phase) = Blocks.patternPlacement(d)
            texture = BevelTexture(name: name, id: id, scale: pct(d, "Scl ", 1), depth: pct(d, "textureDepth", 1), invert: Blocks.boolOf(d, "InvT"),
                                   link: link, phase: phase)
        }
        return Bevel(enabled: notFalse(d, "enab"),
                     style: style,
                     technique: technique,
                     depth: pct(d, "srgR", 1),
                     up: Blocks.enumOf(d, "bvlD") != "Out ",
                     size: f(d, "blur", 5),
                     soften: f(d, "Sftn", 0),
                     angle: f(d, "lagl", 120),
                     altitude: f(d, "Lald", 30),
                     useGlobalLight: notFalse(d, "uglg"),
                     glossContour: self.contour(d, "TrnS"),
                     highlight: FxCommon(enabled: true, blend: blendOf(d, "hglM", .screen), opacity: pct(d, "hglO", 0.75)),
                     highlightColor: Blocks.getDesc(d, "hglC").flatMap(Blocks.colorFromDesc) ?? .white,
                     shadow: FxCommon(enabled: true, blend: blendOf(d, "sdwM", .multiply), opacity: pct(d, "sdwO", 0.75)),
                     shadowColor: color(d, "sdwC"),
                     contour: contour,
                     texture: texture)
    }

    private static func parseOne(_ key: String, _ d: PSDDescriptor) -> Effect? {
        if case .boolean(false)? = d["present"] { return nil }
        switch key {
        case "DrSh": return .dropShadow(parseShadow(d, false))
        case "IrSh": return .innerShadow(parseShadow(d, true))
        case "OrGl": return .outerGlow(parseGlow(d, false))
        case "IrGl": return .innerGlow(parseGlow(d, true))
        case "FrFX": return .stroke(parseStroke(d))
        case "SoFi": return .colorOverlay(Effect.ColorOverlay(common: common(d, .normal, 1), color: color(d, "Clr ")))
        case "GrFl":
            return .gradientOverlay(Effect.GradientOverlay(common: common(d, .normal, 1), gradient: gradientFrom(d), dither: Blocks.boolOf(d, "Dthr")))
        case "patternFill":
            let (name, id) = Blocks.patternRef(d)
            let (angle, link, phase) = Blocks.patternPlacement(d)
            return .patternOverlay(Effect.PatternOverlay(common: common(d, .normal, 1), name: name, id: id, scale: pct(d, "Scl ", 1), angle: angle,
                                                         link: link, phase: phase))
        case "ChFX":
            return .satin(Satin(common: common(d, .multiply, 0.5),
                                color: color(d, "Clr "),
                                angle: f(d, "lagl", 19),
                                distance: f(d, "Dstn", 11),
                                size: f(d, "blur", 14),
                                contour: contour(d, "MpgS"),
                                antiAlias: Blocks.boolOf(d, "AntA"),
                                invert: Blocks.boolOf(d, "Invr")))
        case "ebbl": return .bevelEmboss(parseBevel(d))
        default: return nil
        }
    }
}

// MARK: - Writing

extension EffectsMap {
    /// `UntF` with a unit code; `v` is widened from f32 as photocraft does (after any f32 maths).
    private static func unit(_ u: String, _ v: Float) -> DValue { Blocks.unit(u, Double(v)) }

    private static func enumV(_ t: String, _ v: String) -> DValue { Blocks.enumValue(t, v) }

    private static func contourValue(_ c: Contour) -> DValue {
        let name: String, points: [CurvePoint]
        switch c {
        case .linear: (name, points) = ("Linear", [CurvePoint(input: 0, output: 0), CurvePoint(input: 1, output: 1)])
        case let .custom(cc): (name, points) = (cc.name, cc.points)
        }
        let pts: [DValue] = points.enumerated().map { i, p in
            let d = PSDDescriptor(classID: "CrPt").with("Hrzn", .double(Double(p.input * 255))).with("Vrtc", .double(Double(p.output * 255)))
            // Photoshop writes no `Cnty` (continuity) on smooth points; a corner carries `Cnty` false.
            return .descriptor(c.isCorner(i) ? d.with("Cnty", .boolean(false)) : d)
        }
        return .descriptor(PSDDescriptor(classID: "ShpC").with("Nm  ", Blocks.text(name)).with("Crv ", .list(pts)))
    }

    private static func withCommon(_ d: PSDDescriptor, _ c: FxCommon) -> PSDDescriptor {
        d.with("enab", .boolean(c.enabled))
            .with("present", .boolean(true))
            .with("showInDialog", .boolean(true))
            .with("Md  ", Blocks.blendValue(c.blend))
            .with("Opct", unit("#Prc", c.opacity * 100))
    }

    private static func gradientKeys(_ d: PSDDescriptor, _ g: StyleGradient) -> PSDDescriptor {
        d.with("Grad", .descriptor(Blocks.gradientDesc(g.stops, g.opacityStops)))
            .with("Angl", unit("#Ang", g.angle))
            .with("Type", Blocks.gradientStyleValue(g.style))
            .with("Rvrs", .boolean(g.reverse))
            .with("Algn", .boolean(g.align))
            .with("Scl ", unit("#Prc", g.scale * 100))
            .with("Ofst", .descriptor(PSDDescriptor(classID: "Pnt ").with("Hrzn", unit("#Prc", g.offset.x * 100)).with("Vrtc", unit("#Prc", g.offset.y * 100))))
    }

    private static func writeOne(_ e: Effect) -> (key: String, descriptor: PSDDescriptor) {
        switch e {
        case let .dropShadow(s), let .innerShadow(s):
            let inner: Bool
            if case .innerShadow = e { inner = true } else { inner = false }
            let key = inner ? "IrSh" : "DrSh"
            var d = withCommon(PSDDescriptor(classID: DID(key)), s.common)
                .with("Clr ", .descriptor(Blocks.colorToDesc(s.color)))
                .with("uglg", .boolean(s.useGlobalLight))
                .with("lagl", unit("#Ang", s.angle))
                .with("Dstn", unit("#Pxl", s.distance))
                .with("Ckmt", unit("#Pxl", s.spread * 100))
                .with("blur", unit("#Pxl", s.size))
                .with("Nose", unit("#Prc", s.noise * 100))
                .with("AntA", .boolean(s.antiAlias))
                .with("TrnS", contourValue(s.contour))
            if !inner { d = d.with("layerConceals", .boolean(s.knocksOut)) }
            return (key, d)
        case let .outerGlow(g), let .innerGlow(g):
            let inner: Bool
            if case .innerGlow = e { inner = true } else { inner = false }
            let key = inner ? "IrGl" : "OrGl"
            var d = withCommon(PSDDescriptor(classID: DID(key)), g.common)
            switch g.paint {
            case let .gradient(gr): d = gradientKeys(d, gr)
            case let .color(c): d = d.with("Clr ", .descriptor(Blocks.colorToDesc(c)))
            case .pattern: d = d.with("Clr ", .descriptor(Blocks.colorToDesc(.white)))
            }
            d = d.with("GlwT", enumV("BETE", g.technique == .precise ? "PrBL" : "SfBL"))
                .with("Ckmt", unit("#Pxl", g.spread * 100))
                .with("blur", unit("#Pxl", g.size))
                .with("Nose", unit("#Prc", g.noise * 100))
                .with("ShdN", unit("#Prc", g.jitter * 100))
                .with("AntA", .boolean(g.antiAlias))
                .with("TrnS", contourValue(g.contour))
                .with("Inpr", unit("#Prc", g.range * 100))
            if inner { d = d.with("glwS", enumV("IGSr", g.source == .center ? "SrcC" : "SrcE")) }
            return (key, d)
        case let .stroke(s):
            let styl: String
            switch s.position {
            case .outside: styl = "OutF"
            case .inside: styl = "InsF"
            case .center: styl = "CtrF"
            }
            var d = withCommon(PSDDescriptor(classID: "FrFX"), s.common)
                .with("Styl", enumV("FStl", styl))
                .with("Sz  ", unit("#Pxl", s.size))
            switch s.paint {
            case let .color(c):
                d = d.with("PntT", enumV("FrFl", "SClr")).with("Clr ", .descriptor(Blocks.colorToDesc(c)))
            case let .gradient(g):
                d = gradientKeys(d.with("PntT", enumV("FrFl", "GrFl")), g)
            case let .pattern(p):
                d = d.with("PntT", enumV("FrFl", "Ptrn"))
                    .with("Ptrn", .descriptor(PSDDescriptor(classID: "Ptrn").with("Nm  ", Blocks.text(p.name)).with("Idnt", Blocks.text(p.id))))
                    .with("Scl ", unit("#Prc", p.scale * 100))
            }
            return ("FrFX", d)
        case let .colorOverlay(o):
            return ("SoFi", withCommon(PSDDescriptor(classID: "SoFi"), o.common).with("Clr ", .descriptor(Blocks.colorToDesc(o.color))))
        case let .gradientOverlay(o):
            return ("GrFl", gradientKeys(withCommon(PSDDescriptor(classID: "GrFl"), o.common), o.gradient).with("Dthr", .boolean(o.dither)))
        case let .patternOverlay(o):
            let d = withCommon(PSDDescriptor(classID: "patternFill"), o.common)
                .with("Ptrn", .descriptor(Blocks.patternRefDesc(o.name, o.id)))
                .with("Scl ", unit("#Prc", o.scale * 100))
            return ("patternFill", Blocks.withPatternPlacement(d, o.angle, o.link, o.phase))
        case let .satin(s):
            return ("ChFX", withCommon(PSDDescriptor(classID: "ChFX"), s.common)
                .with("Clr ", .descriptor(Blocks.colorToDesc(s.color)))
                .with("AntA", .boolean(s.antiAlias))
                .with("Invr", .boolean(s.invert))
                .with("lagl", unit("#Ang", s.angle))
                .with("Dstn", unit("#Pxl", s.distance))
                .with("blur", unit("#Pxl", s.size))
                .with("MpgS", contourValue(s.contour)))
        case let .bevelEmboss(b):
            let style: String
            switch b.style {
            case .outerBevel: style = "OtrB"
            case .innerBevel: style = "InrB"
            case .emboss: style = "Embs"
            case .pillowEmboss: style = "PlEb"
            case .strokeEmboss: style = "strokeEmboss"
            }
            let tech: String
            switch b.technique {
            case .smooth: tech = "SfBL"
            case .chiselHard: tech = "PrBL"
            case .chiselSoft: tech = "Slmt"
            }
            var d = PSDDescriptor(classID: "ebbl")
                .with("enab", .boolean(b.enabled))
                .with("present", .boolean(true))
                .with("showInDialog", .boolean(true))
                .with("hglM", Blocks.blendValue(b.highlight.blend))
                .with("hglC", .descriptor(Blocks.colorToDesc(b.highlightColor)))
                .with("hglO", unit("#Prc", b.highlight.opacity * 100))
                .with("sdwM", Blocks.blendValue(b.shadow.blend))
                .with("sdwC", .descriptor(Blocks.colorToDesc(b.shadowColor)))
                .with("sdwO", unit("#Prc", b.shadow.opacity * 100))
                .with("bvlT", enumV("bvlT", tech))
                .with("bvlS", enumV("BESl", style))
                .with("uglg", .boolean(b.useGlobalLight))
                .with("lagl", unit("#Ang", b.angle))
                .with("Lald", unit("#Ang", b.altitude))
                .with("srgR", unit("#Prc", b.depth * 100))
                .with("blur", unit("#Pxl", b.size))
                .with("bvlD", enumV("BESs", b.up ? "In  " : "Out "))
                .with("TrnS", contourValue(b.glossContour))
                .with("Sftn", unit("#Pxl", b.soften))
            if let c = b.contour {
                d = d.with("useShape", .boolean(true))
                    .with("MpgS", contourValue(c.contour))
                    .with("AntA", .boolean(c.antiAlias))
                    .with("Inpr", unit("#Prc", c.range * 100))
            } else {
                d = d.with("useShape", .boolean(false))
            }
            if let t = b.texture {
                d = Blocks.withPatternPlacement(d.with("useTexture", .boolean(true))
                    .with("InvT", .boolean(t.invert))
                    .with("Scl ", unit("#Prc", t.scale * 100))
                    .with("textureDepth", unit("#Prc", t.depth * 100))
                    .with("Ptrn", .descriptor(Blocks.patternRefDesc(t.name, t.id))), 0, t.link, t.phase)
            } else {
                d = d.with("useTexture", .boolean(false))
            }
            return ("ebbl", d)
        }
    }
}
