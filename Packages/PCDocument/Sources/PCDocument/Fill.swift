// Fill layer content (Layer › New Fill Layer): solid colour, gradient or pattern; also the paint
// of shape fills and strokes.
// Port of photocraft-doc (crates/doc/src/lib.rs: `Fill`, `FillCache`), MIT OR Apache-2.0,
// © ArtCraft Team and the PhotoCraft contributors.

import PCFoundation

/// What a fill layer (or a shape's fill/stroke) paints. JSON: serde's externally tagged form
/// (`{"Solid":{…}}`, `{"Gradient":{…}}`, `{"Pattern":{…}}`).
public enum Fill: Hashable, Sendable, Codable {
    case solid(PCColor)
    /// Gradient between stops (see `GradientFill`).
    case gradient(GradientFill)
    /// A pattern from `Document.patterns` (looked up by `id`, then `name`).
    case pattern(PatternFill)

    /// This fill with its colours in `mode`'s model: a fill layer's colours are in its document's
    /// mode, which the compositors read them as.
    public func inMode(_ mode: ColorMode) -> Fill {
        switch self {
        case .solid(let c): return .solid(c.converted(to: mode))
        case .gradient(var g):
            g.stops = g.stops.map { ColorStop($0.location, $0.color.converted(to: mode)) }
            return .gradient(g)
        case .pattern: return self
        }
    }

    public init(from decoder: any Decoder) throws {
        let v = try TaggedVariant(from: decoder)
        switch v.tag {
        case "Solid": self = .solid(try v.payload())
        case "Gradient": self = .gradient(try v.payload())
        case "Pattern": self = .pattern(try v.payload())
        default: throw v.unknown()
        }
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .solid(let c): try Tagged.variant("Solid", c, to: encoder)
        case .gradient(let g): try Tagged.variant("Gradient", g, to: encoder)
        case .pattern(let p): try Tagged.variant("Pattern", p, to: encoder)
        }
    }
}

/// A gradient fill: stops at `angle` degrees (`style` geometry, optionally reversed), laid out in
/// the layer's frame (or the canvas when `align` is off), its centre moved by `offset`.
public struct GradientFill: Hashable, Sendable, Codable {
    public var stops: [ColorStop]
    public var angle: Float
    public var scale: Float
    public var style: GradientStyle
    public var reverse: Bool
    /// Opacity stops `(location, opacity)` (both 0...1); empty = each colour stop's alpha. When
    /// set, a pixel's alpha is the colour's alpha times the opacity at that location.
    public var opacityStops: [OpacityStop]
    /// Colour midpoints, one per segment between consecutive (sorted) colour stops: where the
    /// segment is half-way (0...1 of the segment). Missing entries are 0.5.
    public var midpoints: [Float]
    /// Centre offset as a fraction of the frame (PSD `Ofst`).
    public var offset: SIMD2<Float>
    /// Dither (breaks 8-bit banding with one level of noise).
    public var dither: Bool
    /// "Align with layer": lay out in the layer's frame (its masks' bounds), else the canvas.
    public var align: Bool

    /// A gradient fill with the classic settings: opaque stops at their alpha, 50 % midpoints,
    /// centred, no dither, aligned with the layer (photocraft `Fill::gradient`).
    public init(stops: [ColorStop], angle: Float, scale: Float, style: GradientStyle, reverse: Bool,
                opacityStops: [OpacityStop] = [], midpoints: [Float] = [], offset: SIMD2<Float> = .zero,
                dither: Bool = false, align: Bool = true) {
        self.stops = stops; self.angle = angle; self.scale = scale; self.style = style; self.reverse = reverse
        self.opacityStops = opacityStops; self.midpoints = midpoints; self.offset = offset; self.dither = dither; self.align = align
    }

    enum CodingKeys: String, CodingKey {
        case stops, angle, scale, style, reverse, opacityStops = "opacity_stops", midpoints, offset, dither, align
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        stops = try c.decode([ColorStop].self, forKey: .stops)
        angle = try c.decode(Float.self, forKey: .angle)
        scale = try c.decode(Float.self, forKey: .scale)
        style = try c.decode(GradientStyle.self, forKey: .style)
        reverse = try c.decode(Bool.self, forKey: .reverse)
        opacityStops = try c.decode(.opacityStops, or: [])
        midpoints = try c.decode(.midpoints, or: [])
        offset = try c.decode(.offset, or: .zero)
        dither = try c.decode(.dither, or: false)
        align = try c.decode(.align, or: true)
    }

    /// The midpoint of segment `i` (0.5 when not stored).
    public func midpoint(_ i: Int) -> Float { i >= 0 && i < midpoints.count ? midpoints[i] : 0.5 }
}

/// A pattern fill: a pattern from `Document.patterns` (by `id`, then `name`), scaled, rotated and
/// phased.
public struct PatternFill: Hashable, Sendable, Codable {
    public var name: String
    public var scale: Float
    public var id: String
    /// Rotation in degrees (counter-clockwise).
    public var angle: Float
    /// "Link with Layer": the pattern origin follows the layer's frame (else the canvas).
    public var link: Bool
    /// Phase (origin offset) in pixels.
    public var phase: SIMD2<Float>

    public init(name: String, scale: Float = 1, id: String = "", angle: Float = 0, link: Bool = true, phase: SIMD2<Float> = .zero) {
        self.name = name; self.scale = scale; self.id = id; self.angle = angle; self.link = link; self.phase = phase
    }

    enum CodingKeys: String, CodingKey { case name, scale, id, angle, link, phase }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        scale = try c.decode(Float.self, forKey: .scale)
        id = try c.decode(.id, or: "")
        angle = try c.decode(.angle, or: 0)
        link = try c.decode(.link, or: true)
        phase = try c.decode(.phase, or: .zero)
    }
}

/// Pixels rendered by another application (Photoshop) for a fill layer.
///
/// Used by the compositor instead of rendering the `Fill` itself, but only while `fill` still
/// equals the layer's current fill (editing the fill invalidates the cache automatically).
public struct FillCache: Equatable, Sendable {
    /// The fill these pixels were rendered for.
    public var fill: Fill
    /// Rendered pixels in document coordinates.
    public var surface: Surface

    public init(fill: Fill, surface: Surface) { self.fill = fill; self.surface = surface }
}
