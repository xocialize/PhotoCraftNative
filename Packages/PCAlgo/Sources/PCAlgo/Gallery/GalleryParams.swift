// Port of photocraft-algo (crates/algo/src/artistic.rs; lib.rs `FilterParams::FilterGallery`, `halo_ext`, `label`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Filter › Filter Gallery: the 47 "artistic" filters of Photoshop's gallery (Artistic, Brush
// Strokes, Distort, Sketch, Stylize, Texture), applied as a stack of effect layers in order.
// Each filter is described by photocraft's parameter notation string
// (`{"pencilWidth":1..24=4,"texture":"canvas|brick"}`, first choice = default), the single
// source of truth for its parameters; the pixel work is in GalleryFXCPU.swift / GalleryFXGPU.swift.

import Foundation
import PCFoundation

/// One Filter Gallery filter (photocraft `GalleryFilter`; raw values are its camelCase keys).
public enum GalleryFilter: String, Codable, Sendable, Hashable, CaseIterable {
    // Artistic
    case coloredPencil, cutout, dryBrush, filmGrain, fresco, neonGlow, paintDaubs, paletteKnife, plasticWrap, posterEdges,
         roughPastels, smudgeStick, sponge, underpainting, watercolor
    // Brush Strokes
    case accentedEdges, angledStrokes, crosshatch, darkStrokes, inkOutlines, spatter, sprayedStrokes, sumiE
    // Distort
    case diffuseGlow, glass, oceanRipple
    // Sketch
    case basRelief, chalkCharcoal, charcoal, chrome, conteCrayon, graphicPen, halftonePattern, notePaper, photocopy, plaster,
         reticulation, stamp, tornEdges, waterPaper
    // Stylize
    case glowingEdges
    // Texture
    case craquelure, grain, mosaicTiles, patchwork, stainedGlass, texturizer

    /// Camel-case key (`coloredPencil`); the command id is `filter.gallery.<key>`.
    public var key: String { rawValue }
    public var commandID: String { "filter.gallery." + rawValue }
    /// Display name, gallery folder and parameter notation (photocraft's `gallery!` table).
    public var name: String { Self.table[self]!.name }
    public var category: String { Self.table[self]!.category }
    public var paramsDoc: String { Self.table[self]!.doc }

    /// The gallery's folders, in order (photocraft `GALLERY_CATEGORIES`).
    public static let categories = ["Artistic", "Brush Strokes", "Distort", "Sketch", "Stylize", "Texture"]

    static let table: [GalleryFilter: (name: String, category: String, doc: String)] = [
        .coloredPencil: ("Colored Pencil", "Artistic", #"{"pencilWidth":1..24=4,"strokePressure":0..15=8,"paperBrightness":0..50=25}"#),
        .cutout: ("Cutout", "Artistic", #"{"numberOfLevels":2..8=4,"edgeSimplicity":0..10=4,"edgeFidelity":1..3=2}"#),
        .dryBrush: ("Dry Brush", "Artistic", #"{"brushSize":0..10=2,"brushDetail":0..10=8,"texture":1..3=1}"#),
        .filmGrain: ("Film Grain", "Artistic", #"{"grain":0..20=4,"highlightArea":0..20=0,"intensity":0..10=10}"#),
        .fresco: ("Fresco", "Artistic", #"{"brushSize":0..10=2,"brushDetail":0..10=8,"texture":1..3=1}"#),
        .neonGlow: ("Neon Glow", "Artistic", #"{"glowSize":-24..24=5,"glowBrightness":0..50=15,"glowColor":json}"#),
        .paintDaubs: ("Paint Daubs", "Artistic", #"{"brushSize":1..50=8,"sharpness":0..40=7,"brushType":"simple|lightRough|darkRough|wideSharp|wideBlurry|sparkle"}"#),
        .paletteKnife: ("Palette Knife", "Artistic", #"{"strokeSize":1..50=25,"strokeDetail":1..3=3,"softness":0..10=0}"#),
        .plasticWrap: ("Plastic Wrap", "Artistic", #"{"highlightStrength":0..20=15,"detail":1..15=9,"smoothness":1..15=7}"#),
        .posterEdges: ("Poster Edges", "Artistic", #"{"edgeThickness":0..10=2,"edgeIntensity":0..10=1,"posterization":0..6=2}"#),
        .roughPastels: ("Rough Pastels", "Artistic", #"{"strokeLength":0..40=6,"strokeDetail":1..20=4,"texture":"canvas|brick|burlap|sandstone","scaling":50..200=100,"relief":0..50=20,"light":"bottom|bottomLeft|left|topLeft|top|topRight|right|bottomRight","invert":bool}"#),
        .smudgeStick: ("Smudge Stick", "Artistic", #"{"strokeLength":0..10=2,"highlightArea":0..20=0,"intensity":0..10=10}"#),
        .sponge: ("Sponge", "Artistic", #"{"brushSize":0..10=2,"definition":0..25=12,"smoothness":1..15=5}"#),
        .underpainting: ("Underpainting", "Artistic", #"{"brushSize":0..40=6,"textureCoverage":0..40=16,"texture":"canvas|brick|burlap|sandstone","scaling":50..200=100,"relief":0..50=4,"light":"top|topRight|right|bottomRight|bottom|bottomLeft|left|topLeft","invert":bool}"#),
        .watercolor: ("Watercolor", "Artistic", #"{"brushDetail":1..14=9,"shadowIntensity":0..10=1,"texture":1..3=1}"#),
        .accentedEdges: ("Accented Edges", "Brush Strokes", #"{"edgeWidth":1..14=2,"edgeBrightness":0..50=38,"smoothness":1..15=5}"#),
        .angledStrokes: ("Angled Strokes", "Brush Strokes", #"{"directionBalance":0..100=50,"strokeLength":3..50=15,"sharpness":0..10=3}"#),
        .crosshatch: ("Crosshatch", "Brush Strokes", #"{"strokeLength":3..50=9,"sharpness":0..20=6,"strength":1..3=1}"#),
        .darkStrokes: ("Dark Strokes", "Brush Strokes", #"{"balance":0..10=5,"blackIntensity":0..10=6,"whiteIntensity":0..10=2}"#),
        .inkOutlines: ("Ink Outlines", "Brush Strokes", #"{"strokeLength":1..50=4,"darkIntensity":0..50=20,"lightIntensity":0..50=10}"#),
        .spatter: ("Spatter", "Brush Strokes", #"{"sprayRadius":0..25=10,"smoothness":1..15=5}"#),
        .sprayedStrokes: ("Sprayed Strokes", "Brush Strokes", #"{"strokeLength":0..20=12,"sprayRadius":0..25=7,"strokeDirection":"rightDiagonal|horizontal|leftDiagonal|vertical"}"#),
        .sumiE: ("Sumi-e", "Brush Strokes", #"{"strokeWidth":3..15=10,"strokePressure":0..15=2,"contrast":0..40=16}"#),
        .diffuseGlow: ("Diffuse Glow", "Distort", #"{"graininess":0..10=6,"glowAmount":0..20=10,"clearAmount":0..20=15,"background":json}"#),
        .glass: ("Glass", "Distort", #"{"distortion":0..20=5,"smoothness":1..15=3,"texture":"frosted|blocks|canvas|tinyLens","scaling":50..200=100,"invert":bool}"#),
        .oceanRipple: ("Ocean Ripple", "Distort", #"{"rippleSize":1..15=9,"rippleMagnitude":0..20=9}"#),
        .basRelief: ("Bas Relief", "Sketch", #"{"detail":1..15=13,"smoothness":1..15=3,"light":"bottom|bottomLeft|left|topLeft|top|topRight|right|bottomRight","foreground":json,"background":json}"#),
        .chalkCharcoal: ("Chalk & Charcoal", "Sketch", #"{"charcoalArea":0..20=6,"chalkArea":0..20=6,"strokePressure":0..5=1,"foreground":json,"background":json}"#),
        .charcoal: ("Charcoal", "Sketch", #"{"charcoalThickness":1..7=1,"detail":0..5=5,"lightDarkBalance":0..100=50,"foreground":json,"background":json}"#),
        .chrome: ("Chrome", "Sketch", #"{"detail":0..10=4,"smoothness":0..10=7}"#),
        .conteCrayon: ("Conté Crayon", "Sketch", #"{"foregroundLevel":1..15=11,"backgroundLevel":1..15=7,"texture":"canvas|brick|burlap|sandstone","scaling":50..200=100,"relief":0..50=4,"light":"top|topRight|right|bottomRight|bottom|bottomLeft|left|topLeft","invert":bool,"foreground":json,"background":json}"#),
        .graphicPen: ("Graphic Pen", "Sketch", #"{"strokeLength":1..15=15,"lightDarkBalance":0..100=50,"strokeDirection":"rightDiagonal|horizontal|leftDiagonal|vertical","foreground":json,"background":json}"#),
        .halftonePattern: ("Halftone Pattern", "Sketch", #"{"size":1..12=1,"contrast":0..50=5,"patternType":"dot|circle|line","foreground":json,"background":json}"#),
        .notePaper: ("Note Paper", "Sketch", #"{"imageBalance":0..50=25,"graininess":0..20=10,"relief":0..25=11,"foreground":json,"background":json}"#),
        .photocopy: ("Photocopy", "Sketch", #"{"detail":1..24=7,"darkness":1..50=8,"foreground":json,"background":json}"#),
        .plaster: ("Plaster", "Sketch", #"{"imageBalance":0..50=20,"smoothness":1..15=2,"light":"top|topRight|right|bottomRight|bottom|bottomLeft|left|topLeft","foreground":json,"background":json}"#),
        .reticulation: ("Reticulation", "Sketch", #"{"density":0..50=12,"foregroundLevel":0..50=40,"backgroundLevel":0..50=5,"foreground":json,"background":json}"#),
        .stamp: ("Stamp", "Sketch", #"{"lightDarkBalance":0..50=25,"smoothness":1..50=5,"foreground":json,"background":json}"#),
        .tornEdges: ("Torn Edges", "Sketch", #"{"imageBalance":0..50=25,"smoothness":1..15=11,"contrast":1..25=17,"foreground":json,"background":json}"#),
        .waterPaper: ("Water Paper", "Sketch", #"{"fiberLength":3..50=15,"brightness":0..100=60,"contrast":0..100=80}"#),
        .glowingEdges: ("Glowing Edges", "Stylize", #"{"edgeWidth":1..14=2,"edgeBrightness":0..20=6,"smoothness":1..15=5}"#),
        .craquelure: ("Craquelure", "Texture", #"{"crackSpacing":2..100=15,"crackDepth":0..10=6,"crackBrightness":0..10=9}"#),
        .grain: ("Grain", "Texture", #"{"intensity":0..100=40,"contrast":0..100=50,"grainType":"regular|soft|sprinkles|clumped|contrasty|enlarged|stippled|horizontal|vertical|speckle","foreground":json,"background":json}"#),
        .mosaicTiles: ("Mosaic Tiles", "Texture", #"{"tileSize":2..100=12,"groutWidth":1..15=3,"lightenGrout":0..10=9}"#),
        .patchwork: ("Patchwork", "Texture", #"{"squareSize":0..10=4,"relief":0..25=8}"#),
        .stainedGlass: ("Stained Glass", "Texture", #"{"cellSize":2..50=10,"borderThickness":1..20=4,"lightIntensity":0..10=3,"foreground":json}"#),
        .texturizer: ("Texturizer", "Texture", #"{"texture":"canvas|brick|burlap|sandstone","scaling":50..200=100,"relief":0..50=4,"light":"top|topRight|right|bottomRight|bottom|bottomLeft|left|topLeft","invert":bool}"#),
    ]

    /// Looks a filter up by key (`coloredPencil`), command id or display name (photocraft `from_key`).
    public static func from(key k: String) -> GalleryFilter? {
        let k = k.hasPrefix("filter.gallery.") ? String(k.dropFirst("filter.gallery.".count)) : k
        return allCases.first { $0.key == k || $0.name.caseInsensitiveCompare(k) == .orderedSame }
    }

    /// The numeric / choice / bool parameters parsed from the notation (colours are fields of
    /// `GalleryEffect`, not listed).
    public var params: [GalleryParam] { Self.parsed[self]! }

    static let parsed: [GalleryFilter: [GalleryParam]] = Dictionary(uniqueKeysWithValues: allCases.map { ($0, parse($0.paramsDoc)) })

    static func parse(_ doc: String) -> [GalleryParam] {
        var inner = Substring(doc.trimmingCharacters(in: .whitespaces))
        while inner.first == "{" { inner = inner.dropFirst() }
        while inner.last == "}" { inner = inner.dropLast() }
        var out: [GalleryParam] = []
        for part in inner.split(separator: ",", omittingEmptySubsequences: false) {
            guard let colon = part.firstIndex(of: ":") else { continue }
            let key = part[..<colon].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let v = part[part.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            let kind: GalleryParamKind
            if v.hasPrefix("\"") {
                kind = .choice(v.dropFirst().trimmingCharacters(in: CharacterSet(charactersIn: "\"")).split(separator: "|").map(String.init))
            } else if v == "bool" {
                kind = .bool(false)
            } else if let eq = v.firstIndex(of: "=") {
                let range = v[..<eq], def = v[v.index(after: eq)...]
                let bounds = range.components(separatedBy: "..")
                let p = { (s: String) in Float(s.trimmingCharacters(in: .whitespaces)) ?? 0 }
                let (lo, hi) = bounds.count == 2 ? (p(bounds[0]), p(bounds[1])) : (0, 1)
                kind = .range(min: lo, max: hi, default: p(String(def)))
            } else {
                continue  // json (colours)
            }
            out.append(GalleryParam(key: key, kind: kind))
        }
        return out
    }

    /// Whether the filter reads the foreground / background colours (photocraft `uses_colours`).
    public var usesColours: Bool {
        self == .coloredPencil || self == .neonGlow || paramsDoc.contains("\"foreground\"") || paramsDoc.contains("\"background\"")
    }
}

/// A parameter's kind (photocraft `GalleryParamKind`).
public enum GalleryParamKind: Hashable, Sendable {
    case range(min: Float, max: Float, default: Float)
    /// Choices; the first is the default. Stored as the index.
    case choice([String])
    case bool(Bool)
}

/// A parsed parameter (photocraft `GalleryParam`).
public struct GalleryParam: Hashable, Sendable {
    public var key: String
    public var kind: GalleryParamKind
}

/// One effect layer of the gallery (photocraft `GalleryEffect`): a filter with its values.
/// Choice values are indices into the filter's choice list; bools are 0/1. Colours are straight
/// sRGB RGBA, 0–1 (missing ones decode as black ink, white paper and the Neon Glow blue).
public struct GalleryEffect: Codable, Sendable, Hashable {
    public var filter: GalleryFilter
    public var values: [String: Float]
    public var foreground: SIMD4<Float>
    public var background: SIMD4<Float>
    public var color: SIMD4<Float>

    /// Photoshop's default Neon Glow colour (photocraft `NEON_DEFAULT`).
    public static let neonDefault = SIMD4<Float>(0, 0.62, 1, 1)

    public init(filter: GalleryFilter, values: [String: Float], foreground: SIMD4<Float> = SIMD4(0, 0, 0, 1),
                background: SIMD4<Float> = SIMD4(1, 1, 1, 1), color: SIMD4<Float> = GalleryEffect.neonDefault) {
        self.filter = filter; self.values = values; self.foreground = foreground; self.background = background; self.color = color
    }

    /// The filter with its default values, black ink on white paper (photocraft `GalleryEffect::new`).
    public init(_ filter: GalleryFilter) {
        var v: [String: Float] = [:]
        for p in filter.params {
            switch p.kind {
            case .range(_, _, let d): v[p.key] = d
            case .choice: v[p.key] = 0
            case .bool(let b): v[p.key] = b ? 1 : 0
            }
        }
        self.init(filter: filter, values: v)
    }

    enum CodingKeys: String, CodingKey { case filter, values, foreground, background, color }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        filter = try c.decode(GalleryFilter.self, forKey: .filter)
        values = try c.decodeIfPresent([String: Float].self, forKey: .values) ?? [:]
        foreground = try c.decodeIfPresent(SIMD4<Float>.self, forKey: .foreground) ?? SIMD4(0, 0, 0, 1)
        background = try c.decodeIfPresent(SIMD4<Float>.self, forKey: .background) ?? SIMD4(1, 1, 1, 1)
        color = try c.decodeIfPresent(SIMD4<Float>.self, forKey: .color) ?? Self.neonDefault
    }

    /// Sets a numeric value (clamped to its range), a choice by index, or a bool.
    public mutating func set(_ key: String, _ v: Float) {
        guard let p = filter.params.first(where: { $0.key == key }) else { return }
        switch p.kind {
        case .range(let lo, let hi, _): values[key] = clampf(v, lo, hi)
        case .choice(let c): values[key] = clampf(v.rounded(.toNearestOrAwayFromZero), 0, Float(c.count) - 1)
        case .bool: values[key] = v != 0 ? 1 : 0
        }
    }

    /// Sets a choice by name; false if the name is not one of the choices.
    @discardableResult
    public mutating func setChoice(_ key: String, _ name: String) -> Bool {
        guard case .choice(let c)? = filter.params.first(where: { $0.key == key })?.kind,
              let i = c.firstIndex(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else { return false }
        values[key] = Float(i)
        return true
    }

    /// A numeric value (the default when unset).
    public func get(_ key: String) -> Float {
        if let v = values[key] { return v }
        switch filter.params.first(where: { $0.key == key })?.kind {
        case .range(_, _, let d)?: return d
        case .bool(let b)?: return b ? 1 : 0
        default: return 0
        }
    }

    /// A bool value.
    public func flag(_ key: String) -> Bool { get(key) != 0 }

    /// The chosen name of a choice parameter ("" for other keys).
    public func choice(_ key: String) -> String {
        guard case .choice(let c)? = filter.params.first(where: { $0.key == key })?.kind else { return "" }
        let i = PCAMath.usize(PCAMath.pos(get(key)))
        return i < c.count ? c[i] : c[0]
    }
}

/// Filter › Filter Gallery: a stack of gallery effects applied in order to an sRGB working copy
/// of the source window (the source alpha is kept). photocraft `FilterParams::FilterGallery`.
public struct FilterGallery: Filter, Hashable {
    public var effects: [GalleryEffect]
    public init(effects: [GalleryEffect]) { self.effects = effects }
    public init(_ effects: GalleryEffect...) { self.effects = effects }

    /// photocraft `label`: the effect's name for a one-effect stack.
    public var label: String { effects.count == 1 ? effects[0].filter.name : "Filter Gallery" }
    /// photocraft `Halo::Radius(artistic_fx::reach(effects))`: the effects' reaches add up.
    public func halo(bounds: PixelRect) -> Halo { .radius(GalleryFXKit.reach(effects)) }
    /// The effects work on sRGB colour: Gray- and RGB-like models on the GPU.
    public var gpuChannels: GPUChannels { .joint }

    public func cpu(_ src: FloatImage, out: PixelRect, ctx: FilterContext) -> FloatImage {
        GalleryFXKit.run(effects, src, out, ctx)
    }

    public func encodeGPU(_ pass: GPUPass) throws {
        try GalleryFXKit.encode(effects, pass)
    }
}
