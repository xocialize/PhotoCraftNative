// Layer styles (effects): data only. Rendering lives in the compositor, the PSD mapping in the
// doc⇄PSD layer.
// Port of photocraft-doc (crates/doc/src/effects.rs, and `Effects` from lib.rs),
// MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Angles are in degrees, counter-clockwise from 3 o'clock, and give the direction the light comes
// *from* (Photoshop convention). Sizes and distances are in pixels, opacities and percentages in
// 0...1.

import PCFoundation

/// Gradient geometry (fill layers, gradient overlays, gradient strokes).
public enum GradientStyle: String, CaseIterable, Hashable, Sendable, Codable {
    case linear = "Linear"
    case radial = "Radial"
    case angle = "Angle"
    case reflected = "Reflected"
    case diamond = "Diamond"
}

/// A colour stop: location 0...1 and a colour. JSON: `[location, color]` (photocraft's tuple).
public struct ColorStop: Hashable, Sendable, Codable {
    public var location: Float
    public var color: PCColor

    public init(_ location: Float, _ color: PCColor) { self.location = location; self.color = color }

    public init(from decoder: any Decoder) throws {
        var c = try decoder.unkeyedContainer()
        location = try c.decode(Float.self)
        color = try c.decode(PCColor.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(location)
        try c.encode(color)
    }
}

/// An opacity stop: location and opacity, both 0...1. JSON: `[location, opacity]`.
public struct OpacityStop: Hashable, Sendable, Codable {
    public var location: Float
    public var opacity: Float

    public init(_ location: Float, _ opacity: Float) { self.location = location; self.opacity = opacity }

    public init(from decoder: any Decoder) throws {
        var c = try decoder.unkeyedContainer()
        location = try c.decode(Float.self)
        opacity = try c.decode(Float.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(location)
        try c.encode(opacity)
    }
}

/// A layer-style gradient: colour stops plus transparency stops (both at 0...1) — photocraft
/// `effects::Gradient` (renamed to avoid SwiftUI's `Gradient`).
public struct StyleGradient: Hashable, Sendable, Codable {
    public var stops: [ColorStop]
    /// Opacity stops; empty means fully opaque.
    public var opacityStops: [OpacityStop]
    public var style: GradientStyle
    public var angle: Float
    public var scale: Float
    public var reverse: Bool
    /// Align the gradient with the layer bounds (else the canvas).
    public var align: Bool
    /// Centre offset as a fraction of the bounds.
    public var offset: SIMD2<Float>

    public init(stops: [ColorStop] = [ColorStop(0, .black), ColorStop(1, .white)], opacityStops: [OpacityStop] = [],
                style: GradientStyle = .linear, angle: Float = 90, scale: Float = 1, reverse: Bool = false,
                align: Bool = true, offset: SIMD2<Float> = .zero) {
        self.stops = stops; self.opacityStops = opacityStops; self.style = style; self.angle = angle
        self.scale = scale; self.reverse = reverse; self.align = align; self.offset = offset
    }

    enum CodingKeys: String, CodingKey { case stops, opacityStops = "opacity_stops", style, angle, scale, reverse, align, offset }
}

/// Effect contour (transfer curve applied to the effect's coverage).
/// JSON: `"Linear"` / `{"Custom":{"name":…,"points":[…],"corners":[…]}}`.
public enum Contour: Hashable, Sendable, Codable {
    case linear
    /// Custom curve (input → output), both 0...1.
    case custom(CustomContour)

    public struct CustomContour: Hashable, Sendable, Codable {
        public var name: String
        public var points: [CurvePoint]
        /// Corner (non-continuous) flags, parallel to `points`: the curve bends sharply at a corner
        /// point instead of passing smoothly through it. Missing entries are smooth.
        public var corners: [Bool]

        public init(name: String, points: [CurvePoint], corners: [Bool] = []) {
            self.name = name; self.points = points; self.corners = corners
        }

        enum CodingKeys: String, CodingKey { case name, points, corners }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            points = try c.decode([CurvePoint].self, forKey: .points)
            corners = try c.decode(.corners, or: [])
        }

        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(name, forKey: .name)
            try c.encode(points, forKey: .points)
            if !corners.isEmpty { try c.encode(corners, forKey: .corners) }
        }
    }

    /// Whether point `i` of a custom contour is a corner.
    public func isCorner(_ i: Int) -> Bool {
        guard case .custom(let c) = self, i >= 0, i < c.corners.count else { return false }
        return c.corners[i]
    }

    public init(from decoder: any Decoder) throws {
        let v = try TaggedVariant(from: decoder)
        switch v.tag {
        case "Linear": self = .linear
        case "Custom": self = .custom(try v.payload())
        default: throw v.unknown()
        }
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .linear: try Tagged.unit("Linear", to: encoder)
        case .custom(let c): try Tagged.variant("Custom", c, to: encoder)
        }
    }
}

/// Paint used by strokes and glows. JSON: `{"Color":…}`, `{"Gradient":…}`, `{"Pattern":{…}}`.
public enum FxPaint: Hashable, Sendable, Codable {
    case color(PCColor)
    case gradient(StyleGradient)
    /// Pattern by name/id (rendered once pattern data is available).
    case pattern(PatternRef)

    /// A pattern reference with a scale (strokes, glows).
    public struct PatternRef: Hashable, Sendable, Codable {
        public var name: String
        public var id: String
        public var scale: Float
        public init(name: String, id: String, scale: Float) { self.name = name; self.id = id; self.scale = scale }
    }

    public init(from decoder: any Decoder) throws {
        let v = try TaggedVariant(from: decoder)
        switch v.tag {
        case "Color": self = .color(try v.payload())
        case "Gradient": self = .gradient(try v.payload())
        case "Pattern": self = .pattern(try v.payload())
        default: throw v.unknown()
        }
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .color(let c): try Tagged.variant("Color", c, to: encoder)
        case .gradient(let g): try Tagged.variant("Gradient", g, to: encoder)
        case .pattern(let p): try Tagged.variant("Pattern", p, to: encoder)
        }
    }

    /// This paint with its colours in `mode`'s model.
    public func inMode(_ mode: ColorMode) -> FxPaint {
        switch self {
        case .color(let c): return .color(c.converted(to: mode))
        case .gradient(var g):
            g.stops = g.stops.map { ColorStop($0.location, $0.color.converted(to: mode)) }
            return .gradient(g)
        case .pattern: return self
        }
    }
}

/// Blend mode + opacity + enabled, shared by every effect.
public struct FxCommon: Hashable, Sendable, Codable {
    public var enabled: Bool
    public var blend: BlendMode
    public var opacity: Float

    public init(enabled: Bool = true, blend: BlendMode, opacity: Float) { self.enabled = enabled; self.blend = blend; self.opacity = opacity }
    public init(_ blend: BlendMode, _ opacity: Float) { self.init(enabled: true, blend: blend, opacity: opacity) }
}

/// Drop shadow / inner shadow.
public struct Shadow: Hashable, Sendable, Codable {
    public var common: FxCommon
    public var color: PCColor
    public var angle: Float
    public var useGlobalLight: Bool
    public var distance: Float
    /// Spread (drop shadow) or choke (inner shadow), 0...1.
    public var spread: Float
    public var size: Float
    public var contour: Contour
    public var antiAlias: Bool
    public var noise: Float
    /// Drop shadow only: the layer knocks out the shadow beneath it.
    public var knocksOut: Bool

    public init(common: FxCommon, color: PCColor = .black, angle: Float = 120, useGlobalLight: Bool = true, distance: Float = 5,
                spread: Float = 0, size: Float = 5, contour: Contour = .linear, antiAlias: Bool = false, noise: Float = 0, knocksOut: Bool = true) {
        self.common = common; self.color = color; self.angle = angle; self.useGlobalLight = useGlobalLight
        self.distance = distance; self.spread = spread; self.size = size; self.contour = contour
        self.antiAlias = antiAlias; self.noise = noise; self.knocksOut = knocksOut
    }

    enum CodingKeys: String, CodingKey {
        case common, color, angle, useGlobalLight = "use_global_light", distance, spread, size, contour
        case antiAlias = "anti_alias", noise, knocksOut = "knocks_out"
    }
}

public enum GlowTechnique: String, CaseIterable, Hashable, Sendable, Codable {
    case softer = "Softer"
    case precise = "Precise"
}

public enum GlowSource: String, CaseIterable, Hashable, Sendable, Codable {
    case center = "Center"
    case edge = "Edge"
}

/// Outer glow / inner glow.
public struct Glow: Hashable, Sendable, Codable {
    public var common: FxCommon
    public var paint: FxPaint
    public var technique: GlowTechnique
    /// Spread (outer) or choke (inner), 0...1.
    public var spread: Float
    public var size: Float
    public var contour: Contour
    public var antiAlias: Bool
    public var range: Float
    public var jitter: Float
    public var noise: Float
    /// Inner glow only.
    public var source: GlowSource

    public init(common: FxCommon, paint: FxPaint, technique: GlowTechnique = .softer, spread: Float = 0, size: Float = 5,
                contour: Contour = .linear, antiAlias: Bool = false, range: Float = 0.5, jitter: Float = 0, noise: Float = 0,
                source: GlowSource = .edge) {
        self.common = common; self.paint = paint; self.technique = technique; self.spread = spread; self.size = size
        self.contour = contour; self.antiAlias = antiAlias; self.range = range; self.jitter = jitter; self.noise = noise
        self.source = source
    }

    enum CodingKeys: String, CodingKey {
        case common, paint, technique, spread, size, contour, antiAlias = "anti_alias", range, jitter, noise, source
    }
}

public enum StrokePosition: String, CaseIterable, Hashable, Sendable, Codable {
    case outside = "Outside"
    case inside = "Inside"
    case center = "Center"
}

/// The Stroke layer style.
public struct StrokeFx: Hashable, Sendable, Codable {
    public var common: FxCommon
    public var size: Float
    public var position: StrokePosition
    public var paint: FxPaint

    public init(common: FxCommon, size: Float, position: StrokePosition, paint: FxPaint) {
        self.common = common; self.size = size; self.position = position; self.paint = paint
    }
}

/// The Satin layer style.
public struct Satin: Hashable, Sendable, Codable {
    public var common: FxCommon
    public var color: PCColor
    public var angle: Float
    public var distance: Float
    public var size: Float
    public var contour: Contour
    public var antiAlias: Bool
    public var invert: Bool

    public init(common: FxCommon, color: PCColor, angle: Float, distance: Float, size: Float, contour: Contour = .linear,
                antiAlias: Bool = false, invert: Bool = true) {
        self.common = common; self.color = color; self.angle = angle; self.distance = distance
        self.size = size; self.contour = contour; self.antiAlias = antiAlias; self.invert = invert
    }

    enum CodingKeys: String, CodingKey { case common, color, angle, distance, size, contour, antiAlias = "anti_alias", invert }
}

public enum BevelStyle: String, CaseIterable, Hashable, Sendable, Codable {
    case outerBevel = "OuterBevel"
    case innerBevel = "InnerBevel"
    case emboss = "Emboss"
    case pillowEmboss = "PillowEmboss"
    case strokeEmboss = "StrokeEmboss"
}

public enum BevelTechnique: String, CaseIterable, Hashable, Sendable, Codable {
    case smooth = "Smooth"
    case chiselHard = "ChiselHard"
    case chiselSoft = "ChiselSoft"
}

/// The Bevel & Emboss layer style.
public struct Bevel: Hashable, Sendable, Codable {
    public var enabled: Bool
    public var style: BevelStyle
    public var technique: BevelTechnique
    /// Depth, 0...10 (1 = 100 %).
    public var depth: Float
    /// Direction up (true) or down.
    public var up: Bool
    public var size: Float
    public var soften: Float
    public var angle: Float
    public var altitude: Float
    public var useGlobalLight: Bool
    public var glossContour: Contour
    public var highlight: FxCommon
    public var highlightColor: PCColor
    public var shadow: FxCommon
    public var shadowColor: PCColor
    /// Bevel & Emboss › Contour: shapes the bevel's height profile. nil = off.
    public var contour: BevelContour?
    /// Bevel & Emboss › Texture: a pattern's luminance added to the height. nil = off.
    public var texture: BevelTexture?

    /// Photoshop's defaults.
    public init(enabled: Bool = true, style: BevelStyle = .innerBevel, technique: BevelTechnique = .smooth, depth: Float = 1,
                up: Bool = true, size: Float = 5, soften: Float = 0, angle: Float = 120, altitude: Float = 30,
                useGlobalLight: Bool = true, glossContour: Contour = .linear,
                highlight: FxCommon = FxCommon(.screen, 0.75), highlightColor: PCColor = .white,
                shadow: FxCommon = FxCommon(.multiply, 0.75), shadowColor: PCColor = .black,
                contour: BevelContour? = nil, texture: BevelTexture? = nil) {
        self.enabled = enabled; self.style = style; self.technique = technique; self.depth = depth; self.up = up
        self.size = size; self.soften = soften; self.angle = angle; self.altitude = altitude; self.useGlobalLight = useGlobalLight
        self.glossContour = glossContour; self.highlight = highlight; self.highlightColor = highlightColor
        self.shadow = shadow; self.shadowColor = shadowColor; self.contour = contour; self.texture = texture
    }

    enum CodingKeys: String, CodingKey {
        case enabled, style, technique, depth, up, size, soften, angle, altitude, useGlobalLight = "use_global_light"
        case glossContour = "gloss_contour", highlight, highlightColor = "highlight_color", shadow, shadowColor = "shadow_color"
        case contour, texture
    }
}

/// The Contour element of Bevel & Emboss.
public struct BevelContour: Hashable, Sendable, Codable {
    public var contour: Contour
    /// Range 0...1 (Photoshop's default 50 %): the part of the bevel the contour spans.
    public var range: Float
    public var antiAlias: Bool

    public init(contour: Contour = .linear, range: Float = 0.5, antiAlias: Bool = false) {
        self.contour = contour; self.range = range; self.antiAlias = antiAlias
    }

    enum CodingKeys: String, CodingKey { case contour, range, antiAlias = "anti_alias" }
}

/// The Texture element of Bevel & Emboss.
public struct BevelTexture: Hashable, Sendable, Codable {
    public var name: String
    public var id: String
    /// Scale as a fraction (1 = 100 %).
    public var scale: Float
    /// Depth -10...10 (1 = +100 %); negative carves the pattern in.
    public var depth: Float
    public var invert: Bool
    /// "Link with Layer": tile from the layer (else the canvas origin).
    public var link: Bool
    public var phase: SIMD2<Float>

    public init(name: String, id: String, scale: Float = 1, depth: Float = 1, invert: Bool = false, link: Bool = true, phase: SIMD2<Float> = .zero) {
        self.name = name; self.id = id; self.scale = scale; self.depth = depth; self.invert = invert; self.link = link; self.phase = phase
    }
}

/// One layer effect. Several instances of the same kind are allowed (Photoshop's multiple
/// strokes/shadows/overlays). JSON: serde's externally tagged form (`{"DropShadow":{…}}`).
public enum Effect: Hashable, Sendable, Codable {
    case dropShadow(Shadow)
    case innerShadow(Shadow)
    case outerGlow(Glow)
    case innerGlow(Glow)
    case stroke(StrokeFx)
    case colorOverlay(ColorOverlay)
    case gradientOverlay(GradientOverlay)
    case patternOverlay(PatternOverlay)
    case satin(Satin)
    case bevelEmboss(Bevel)

    public struct ColorOverlay: Hashable, Sendable, Codable {
        public var common: FxCommon
        public var color: PCColor
        public init(common: FxCommon, color: PCColor) { self.common = common; self.color = color }
    }

    public struct GradientOverlay: Hashable, Sendable, Codable {
        public var common: FxCommon
        public var gradient: StyleGradient
        public var dither: Bool
        public init(common: FxCommon, gradient: StyleGradient, dither: Bool = false) {
            self.common = common; self.gradient = gradient; self.dither = dither
        }
    }

    public struct PatternOverlay: Hashable, Sendable, Codable {
        public var common: FxCommon
        public var name: String
        public var id: String
        public var scale: Float
        /// Rotation in degrees (counter-clockwise).
        public var angle: Float
        /// "Link with Layer": the pattern origin follows the layer (else the canvas).
        public var link: Bool
        /// Phase (origin offset) in pixels.
        public var phase: SIMD2<Float>

        public init(common: FxCommon, name: String, id: String, scale: Float = 1, angle: Float = 0, link: Bool = true, phase: SIMD2<Float> = .zero) {
            self.common = common; self.name = name; self.id = id; self.scale = scale; self.angle = angle; self.link = link; self.phase = phase
        }

        enum CodingKeys: String, CodingKey { case common, name, id, scale, angle, link, phase }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            common = try c.decode(FxCommon.self, forKey: .common)
            name = try c.decode(String.self, forKey: .name)
            id = try c.decode(String.self, forKey: .id)
            scale = try c.decode(Float.self, forKey: .scale)
            angle = try c.decode(.angle, or: 0)
            link = try c.decode(.link, or: true)
            phase = try c.decode(.phase, or: .zero)
        }
    }

    /// This effect with its colours in `mode`'s model: a layer's effect colours are in its
    /// document's mode, as Image › Mode keeps them.
    public func inMode(_ mode: ColorMode) -> Effect {
        switch self {
        case .dropShadow(var s): s.color = s.color.converted(to: mode); return .dropShadow(s)
        case .innerShadow(var s): s.color = s.color.converted(to: mode); return .innerShadow(s)
        case .outerGlow(var g): g.paint = g.paint.inMode(mode); return .outerGlow(g)
        case .innerGlow(var g): g.paint = g.paint.inMode(mode); return .innerGlow(g)
        case .stroke(var s): s.paint = s.paint.inMode(mode); return .stroke(s)
        case .colorOverlay(var o): o.color = o.color.converted(to: mode); return .colorOverlay(o)
        case .gradientOverlay(var o):
            o.gradient.stops = o.gradient.stops.map { ColorStop($0.location, $0.color.converted(to: mode)) }
            return .gradientOverlay(o)
        case .satin(var s): s.color = s.color.converted(to: mode); return .satin(s)
        case .bevelEmboss(var b):
            b.highlightColor = b.highlightColor.converted(to: mode)
            b.shadowColor = b.shadowColor.converted(to: mode)
            return .bevelEmboss(b)
        case .patternOverlay: return self
        }
    }

    /// Whether this instance is switched on (photocraft `enabled()`).
    public var isEnabled: Bool {
        get {
            switch self {
            case .dropShadow(let s), .innerShadow(let s): s.common.enabled
            case .outerGlow(let g), .innerGlow(let g): g.common.enabled
            case .stroke(let s): s.common.enabled
            case .colorOverlay(let o): o.common.enabled
            case .gradientOverlay(let o): o.common.enabled
            case .patternOverlay(let o): o.common.enabled
            case .satin(let s): s.common.enabled
            case .bevelEmboss(let b): b.enabled
            }
        }
        set { setEnabled(newValue) }
    }

    /// Switches this instance on or off, keeping its settings.
    public mutating func setEnabled(_ on: Bool) {
        switch self {
        case .dropShadow(var s): s.common.enabled = on; self = .dropShadow(s)
        case .innerShadow(var s): s.common.enabled = on; self = .innerShadow(s)
        case .outerGlow(var g): g.common.enabled = on; self = .outerGlow(g)
        case .innerGlow(var g): g.common.enabled = on; self = .innerGlow(g)
        case .stroke(var s): s.common.enabled = on; self = .stroke(s)
        case .colorOverlay(var o): o.common.enabled = on; self = .colorOverlay(o)
        case .gradientOverlay(var o): o.common.enabled = on; self = .gradientOverlay(o)
        case .patternOverlay(var o): o.common.enabled = on; self = .patternOverlay(o)
        case .satin(var s): s.common.enabled = on; self = .satin(s)
        case .bevelEmboss(var b): b.enabled = on; self = .bevelEmboss(b)
        }
    }

    /// Short label for UIs.
    public var label: String {
        switch self {
        case .dropShadow: "Drop Shadow"
        case .innerShadow: "Inner Shadow"
        case .outerGlow: "Outer Glow"
        case .innerGlow: "Inner Glow"
        case .stroke: "Stroke"
        case .colorOverlay: "Color Overlay"
        case .gradientOverlay: "Gradient Overlay"
        case .patternOverlay: "Pattern Overlay"
        case .satin: "Satin"
        case .bevelEmboss: "Bevel & Emboss"
        }
    }

    /// Photoshop's defaults for a drop shadow.
    public static func defaultDropShadow() -> Effect {
        .dropShadow(Shadow(common: FxCommon(.multiply, 0.75), color: .black, angle: 120, useGlobalLight: true, distance: 5,
                           spread: 0, size: 5, contour: .linear, antiAlias: false, noise: 0, knocksOut: true))
    }

    public init(from decoder: any Decoder) throws {
        let v = try TaggedVariant(from: decoder)
        switch v.tag {
        case "DropShadow": self = .dropShadow(try v.payload())
        case "InnerShadow": self = .innerShadow(try v.payload())
        case "OuterGlow": self = .outerGlow(try v.payload())
        case "InnerGlow": self = .innerGlow(try v.payload())
        case "Stroke": self = .stroke(try v.payload())
        case "ColorOverlay": self = .colorOverlay(try v.payload())
        case "GradientOverlay": self = .gradientOverlay(try v.payload())
        case "PatternOverlay": self = .patternOverlay(try v.payload())
        case "Satin": self = .satin(try v.payload())
        case "BevelEmboss": self = .bevelEmboss(try v.payload())
        default: throw v.unknown()
        }
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .dropShadow(let p): try Tagged.variant("DropShadow", p, to: encoder)
        case .innerShadow(let p): try Tagged.variant("InnerShadow", p, to: encoder)
        case .outerGlow(let p): try Tagged.variant("OuterGlow", p, to: encoder)
        case .innerGlow(let p): try Tagged.variant("InnerGlow", p, to: encoder)
        case .stroke(let p): try Tagged.variant("Stroke", p, to: encoder)
        case .colorOverlay(let p): try Tagged.variant("ColorOverlay", p, to: encoder)
        case .gradientOverlay(let p): try Tagged.variant("GradientOverlay", p, to: encoder)
        case .patternOverlay(let p): try Tagged.variant("PatternOverlay", p, to: encoder)
        case .satin(let p): try Tagged.variant("Satin", p, to: encoder)
        case .bevelEmboss(let p): try Tagged.variant("BevelEmboss", p, to: encoder)
        }
    }
}

/// Document-wide light used by effects with `useGlobalLight`.
public struct GlobalLight: Hashable, Sendable, Codable {
    public var angle: Float
    public var altitude: Float
    public init(angle: Float = 120, altitude: Float = 30) { self.angle = angle; self.altitude = altitude }
}

/// A layer's style: the effect instances, the master switch and preserved PSD data.
/// (Not serde in photocraft; Codable here with snake_case keys for convenience.)
public struct Effects: Hashable, Sendable, Codable {
    public var enabled: Bool
    public var items: [Effect]
    /// Original PSD `lfx2` (`lfxs` on groups) block data (object-effects version + descriptor),
    /// written back verbatim on PSD export. Not duplicated in `Layer.psdBlocks`.
    public var psdRaw: [UInt8]?
    /// Effects reference point (PSD `fxrp`): where linked patterns (Pattern Overlay, pattern
    /// strokes and glows) anchor their tiling. It moves with the layer. nil = the layer's top-left.
    public var reference: SIMD2<Double>?

    /// `enabled` defaults to false, as photocraft's `Effects::default()`; `Layer.init` turns it on.
    public init(enabled: Bool = false, items: [Effect] = [], psdRaw: [UInt8]? = nil, reference: SIMD2<Double>? = nil) {
        self.enabled = enabled; self.items = items; self.psdRaw = psdRaw; self.reference = reference
    }

    /// Whether any enabled effect would draw (master switch on and at least one instance on).
    public var hasVisibleEffects: Bool { enabled && items.contains { $0.isEnabled } }

    enum CodingKeys: String, CodingKey { case enabled, items, psdRaw = "psd_raw", reference }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decode(.enabled, or: false)
        items = try c.decode(.items, or: [])
        psdRaw = try c.decodeIfPresent([UInt8].self, forKey: .psdRaw)
        reference = try c.decodeIfPresent(SIMD2<Double>.self, forKey: .reference)
    }
}
