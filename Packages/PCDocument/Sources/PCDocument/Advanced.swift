// Layer Style › Blending Options › Advanced Blending: knockout and the "as group" / "hides
// effects" switches. Fill opacity (`Layer.fillOpacity`), the channel restrictions
// (`Layer.excludedChannels`) and Blend If (`Layer.blendIf`) live on the layer itself; this struct
// holds the rest of the section.
// Port of photocraft-doc (crates/doc/src/advanced.rs), MIT OR Apache-2.0, © ArtCraft Team and the
// PhotoCraft contributors.
//
// Defaults are Photoshop's: no knockout, interior effects blended separately, clipped layers
// blended as a group, transparency shaping the layer's effects and knockout, and masks applied
// before the effects are built (so the effects follow the masked shape).
//
// PSD: `knko` (0 none, 1 shallow, 2 deep), `infx`, `clbl`, `tsly`, `lmgm`, `vmgm`, each a one-byte
// flag followed by three bytes of padding (Adobe Photoshop File Format specification, "Additional
// Layer Information").

/// Blending Options › Advanced Blending › Knockout: which layers beneath this one its shape
/// punches through. Fill opacity controls the strength (0 % fill shows the knocked-out area bare).
/// JSON: `"none"`, `"shallow"`, `"deep"`.
public enum Knockout: String, CaseIterable, Hashable, Sendable, Codable {
    /// The layer blends with everything beneath it (the default).
    case none
    /// Knocks out to the bottom of the enclosing layer group or clipping group (for a layer at the
    /// top level: to the Background layer, or to transparency without one).
    case shallow
    /// Knocks out to the Background layer (to transparency without one), through every group.
    case deep

    /// The PSD `knko` value (0 none, 1 shallow, 2 deep).
    public var psdValue: UInt8 {
        switch self { case .none: 0; case .shallow: 1; case .deep: 2 }
    }

    /// From a PSD `knko` value; values above 2 (not written by Photoshop) read as deep.
    public init(psdValue v: UInt8) {
        switch v { case 0: self = .none; case 1: self = .shallow; default: self = .deep }
    }

    /// The parameter / UI name (`none`, `shallow`, `deep`).
    public var name: String { rawValue }

    /// Inverse of `name` (case-insensitive).
    public init?(name: String) { self.init(rawValue: name.lowercased()) }
}

/// The Advanced Blending switches of a layer (see the file header). `init()` is Photoshop's
/// default. JSON keys are camelCase and every key is optional.
public struct AdvancedBlending: Hashable, Sendable, Codable {
    /// Knockout: None / Shallow / Deep. PSD `knko`.
    public var knockout: Knockout = .none
    /// Blend Interior Effects as Group: Inner Glow, Satin and the Color, Gradient and Pattern
    /// Overlays are combined with the layer's content before its fill opacity and blend mode
    /// apply (off: fill opacity leaves them alone). PSD `infx`, default off.
    public var blendInterior = false
    /// Blend Clipped Layers as Group: the clipping group composites as a whole in the base layer's
    /// blend mode (off: each clipped layer blends with the layers beneath the base in its own mode,
    /// inside the base's shape). PSD `clbl`, default on.
    public var blendClipped = true
    /// Transparency Shapes Layer: the layer's transparency limits its effects and knockout (off:
    /// they cover the whole layer). PSD `tsly`, default on.
    public var transparencyShapes = true
    /// Layer Mask Hides Effects: the layer mask hides the effects instead of shaping them. PSD
    /// `lmgm` ("layer mask as global mask"), default off.
    public var layerMaskHidesEffects = false
    /// Vector Mask Hides Effects: the vector mask hides the effects instead of shaping them. PSD
    /// `vmgm`, default off.
    public var vectorMaskHidesEffects = false

    public init(knockout: Knockout = .none, blendInterior: Bool = false, blendClipped: Bool = true, transparencyShapes: Bool = true,
                layerMaskHidesEffects: Bool = false, vectorMaskHidesEffects: Bool = false) {
        self.knockout = knockout; self.blendInterior = blendInterior; self.blendClipped = blendClipped
        self.transparencyShapes = transparencyShapes; self.layerMaskHidesEffects = layerMaskHidesEffects
        self.vectorMaskHidesEffects = vectorMaskHidesEffects
    }

    /// Whether every switch is at Photoshop's default.
    public var isDefault: Bool { self == AdvancedBlending() }

    enum CodingKeys: String, CodingKey {
        case knockout, blendInterior, blendClipped, transparencyShapes, layerMaskHidesEffects, vectorMaskHidesEffects
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AdvancedBlending()
        knockout = try c.decode(.knockout, or: d.knockout)
        blendInterior = try c.decode(.blendInterior, or: d.blendInterior)
        blendClipped = try c.decode(.blendClipped, or: d.blendClipped)
        transparencyShapes = try c.decode(.transparencyShapes, or: d.transparencyShapes)
        layerMaskHidesEffects = try c.decode(.layerMaskHidesEffects, or: d.layerMaskHidesEffects)
        vectorMaskHidesEffects = try c.decode(.vectorMaskHidesEffects, or: d.vectorMaskHidesEffects)
    }
}
