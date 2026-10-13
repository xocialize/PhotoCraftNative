// Layer comps (Window › Layer Comps) and artboards: pure data plus capture helpers that need
// nothing beyond the document model.
// Port of photocraft-doc (crates/doc/src/comps.rs), MIT OR Apache-2.0, © ArtCraft Team and the
// PhotoCraft contributors.
//
// A layer comp records, per layer, its visibility, position and appearance (blend mode, opacity,
// fill opacity, layer style). Three flags choose which of those applying restores, like the
// checkboxes of Photoshop's Layer Comp Options. Position is the top-left of the layer's content
// bounds (artboards: of the board), so applying a comp moves a layer by the difference between
// that and where it is now.

import PCFoundation

/// One layer's state as captured by a comp. nil = not recorded (PSD comps record only what their
/// capture flags asked for).
public struct CompLayerState: Equatable, Sendable {
    public var layer: LayerId
    public var visible: Bool?
    /// Top-left of the content bounds (or artboard rect). nil for layers without a position
    /// (adjustment and fill layers, empty layers, plain groups).
    public var position: SIMD2<Int32>?
    public var appearance: CompAppearance?

    public init(layer: LayerId, visible: Bool? = nil, position: SIMD2<Int32>? = nil, appearance: CompAppearance? = nil) {
        self.layer = layer; self.visible = visible; self.position = position; self.appearance = appearance
    }
}

/// Layer › Layer Style state captured by "Appearance".
public struct CompAppearance: Equatable, Sendable {
    public var blend: BlendMode
    public var opacity: Float
    public var fillOpacity: Float
    public var effects: Effects

    public init(blend: BlendMode, opacity: Float, fillOpacity: Float, effects: Effects) {
        self.blend = blend; self.opacity = opacity; self.fillOpacity = fillOpacity; self.effects = effects
    }
}

/// A layer comp.
public struct LayerComp: Equatable, Sendable {
    /// Stable id (the PSD `compID`). Never 0: Photoshop uses 0 for the Last Document State.
    public var id: UInt32
    public var name: String
    public var comment: String
    public var applyVisibility: Bool
    public var applyPosition: Bool
    public var applyAppearance: Bool
    /// Per-layer state, in document walk order.
    public var states: [CompLayerState]

    public init(id: UInt32, name: String, comment: String = "", applyVisibility: Bool = true, applyPosition: Bool = true,
                applyAppearance: Bool = true, states: [CompLayerState] = []) {
        self.id = id; self.name = name; self.comment = comment; self.applyVisibility = applyVisibility
        self.applyPosition = applyPosition; self.applyAppearance = applyAppearance; self.states = states
    }

    /// PSD `capturedInfo` bit flags: 1 visibility, 2 position, 4 appearance.
    public var capturedInfo: Int32 {
        get { (applyVisibility ? 1 : 0) | (applyPosition ? 2 : 0) | (applyAppearance ? 4 : 0) }
        set {
            applyVisibility = newValue & 1 != 0
            applyPosition = newValue & 2 != 0
            applyAppearance = newValue & 4 != 0
        }
    }

    public func state(_ id: LayerId) -> CompLayerState? { states.first { $0.layer == id } }

    /// Ids of recorded layers that no longer exist in `doc` (Photoshop's warning triangle).
    public func missingLayers(in doc: Document) -> [LayerId] {
        states.map(\.layer).filter { !doc.contains($0) }
    }
}

extension Layer {
    /// Content bounds used for comp positions: pixels (or the rendered cache) of a layer, the board
    /// of an artboard. Empty for adjustment/fill layers and plain groups.
    public var positionBounds: PixelRect {
        switch content {
        case .group(let g): return g.artboard?.rect ?? .empty
        case .adjustment, .fill: return .empty
        default: return surface?.contentBounds ?? .empty
        }
    }

    /// Comp position of a layer (see `positionBounds`).
    public var compPosition: SIMD2<Int32>? {
        let r = positionBounds
        return r.isEmpty ? nil : SIMD2(r.x0, r.y0)
    }
}

extension Document {
    /// Capture the full state of every layer.
    public func captureCompStates() -> [CompLayerState] {
        var out: [CompLayerState] = []
        forEachLayer { _, _, l in
            out.append(CompLayerState(layer: l.id, visible: l.visible, position: l.compPosition,
                                      appearance: CompAppearance(blend: l.blend, opacity: l.opacity, fillOpacity: l.fillOpacity, effects: l.effects)))
        }
        return out
    }

    /// A fresh comp id, unique among this document's comps (never 0).
    public func nextCompId() -> UInt32 {
        // Photoshop uses large pseudo-random ids; any unique non-zero value round-trips.
        var id = max((layerComps.map(\.id).max() ?? 0) &+ 1, 1)
        while layerComps.contains(where: { $0.id == id }) { id = max(id &+ 1, 1) }
        return id
    }

    /// Top-level artboards, bottom to top.
    public var artboards: [(id: LayerId, name: String, artboard: Artboard)] {
        layers.compactMap { l in l.artboard.map { (l.id, l.name, $0) } }
    }

    public var hasArtboards: Bool { layers.contains { $0.artboard != nil } }

    public func comp(_ id: UInt32) -> LayerComp? { layerComps.first { $0.id == id } }

    /// The artboard containing layer `id` (itself, or its top-level ancestor).
    public func artboard(of id: LayerId) -> LayerId? {
        guard let p = path(of: id), let first = p.first, first < layers.count else { return nil }
        let top = layers[first]
        return top.artboard != nil ? top.id : nil
    }
}

/// What an artboard paints behind its contents. JSON: `"white"`, `"black"`, `"transparent"`,
/// `{"custom":{…colour…}}`.
public enum ArtboardBackground: Hashable, Sendable, Codable {
    case white
    case black
    case transparent
    case custom(PCColor)

    /// sRGB colour painted under the contents (nil = transparent).
    public var rgba: SIMD4<Float>? {
        switch self {
        case .white: return SIMD4(1, 1, 1, 1)
        case .black: return SIMD4(0, 0, 0, 1)
        case .transparent: return nil
        case .custom(let c): return c.alpha > 0 ? SIMD4(c.rgb, c.alpha) : nil
        }
    }

    /// PSD `artboardBackgroundType`: 1 white, 2 black, 3 transparent, 4 other.
    public var psdType: Int32 {
        switch self { case .white: 1; case .black: 2; case .transparent: 3; case .custom: 4 }
    }

    public var name: String {
        switch self { case .white: "white"; case .black: "black"; case .transparent: "transparent"; case .custom: "custom" }
    }

    public init(from decoder: any Decoder) throws {
        let v = try TaggedVariant(from: decoder)
        switch v.tag {
        case "white": self = .white
        case "black": self = .black
        case "transparent": self = .transparent
        case "custom": self = .custom(try v.payload())
        default: throw v.unknown()
        }
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .white, .black, .transparent: try Tagged.unit(name, to: encoder)
        case .custom(let c): try Tagged.variant("custom", c, to: encoder)
        }
    }
}

/// An artboard: a top-level group that clips its children to `rect` and paints `background`
/// behind them (Layer › New › Artboard).
public struct Artboard: Hashable, Sendable, Codable {
    /// The board in document pixels.
    public var rect: PixelRect
    public var background: ArtboardBackground
    /// Size preset the board was made from ("" = custom).
    public var preset: String

    public init(rect: PixelRect, background: ArtboardBackground = .white, preset: String = "") {
        self.rect = rect; self.background = background; self.preset = preset
    }

    enum CodingKeys: String, CodingKey { case rect, background, preset }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rect = try c.decode(PixelRect.self, forKey: .rect)
        background = try c.decode(ArtboardBackground.self, forKey: .background)
        preset = try c.decode(.preset, or: "")
    }
}
