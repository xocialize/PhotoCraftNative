// Layer blend modes: the four-character keys stored after the `8BIM` signature of a layer record.
// Port of photocraft-psd (crates/psd/src/blend.rs), MIT OR Apache-2.0, © ArtCraft Team and the
// PhotoCraft contributors.

/// Photoshop blend mode keys (27 layer modes plus pass-through for groups). Unknown keys are kept
/// verbatim so they round-trip.
public enum PSDBlendMode: Hashable, Sendable, CustomStringConvertible {
    case passThrough, normal, dissolve
    case darken, multiply, colorBurn, linearBurn, darkerColor
    case lighten, screen, colorDodge, linearDodge, lighterColor
    case overlay, softLight, hardLight, vividLight, linearLight, pinLight, hardMix
    case difference, exclusion, subtract, divide
    case hue, saturation, color, luminosity
    /// A key this package does not know, preserved.
    case unknown(FourCC)

    /// All known modes, pass-through first (28).
    public static let all: [PSDBlendMode] = [
        .passThrough, .normal, .dissolve, .darken, .multiply, .colorBurn, .linearBurn, .darkerColor,
        .lighten, .screen, .colorDodge, .linearDodge, .lighterColor, .overlay, .softLight, .hardLight,
        .vividLight, .linearLight, .pinLight, .hardMix, .difference, .exclusion, .subtract, .divide,
        .hue, .saturation, .color, .luminosity,
    ]

    public var key: FourCC {
        switch self {
        case .passThrough: "pass"
        case .normal: "norm"
        case .dissolve: "diss"
        case .darken: "dark"
        case .multiply: "mul "
        case .colorBurn: "idiv"
        case .linearBurn: "lbrn"
        case .darkerColor: "dkCl"
        case .lighten: "lite"
        case .screen: "scrn"
        case .colorDodge: "div "
        case .linearDodge: "lddg"
        case .lighterColor: "lgCl"
        case .overlay: "over"
        case .softLight: "sLit"
        case .hardLight: "hLit"
        case .vividLight: "vLit"
        case .linearLight: "lLit"
        case .pinLight: "pLit"
        case .hardMix: "hMix"
        case .difference: "diff"
        case .exclusion: "smud"
        case .subtract: "fsub"
        case .divide: "fdiv"
        case .hue: "hue "
        case .saturation: "sat "
        case .color: "colr"
        case .luminosity: "lum "
        case let .unknown(k): k
        }
    }

    private static let byKey: [FourCC: PSDBlendMode] = Dictionary(uniqueKeysWithValues: all.map { ($0.key, $0) })

    public init(key: FourCC) {
        self = PSDBlendMode.byKey[key] ?? .unknown(key)
    }

    /// The descriptor enumeration value Photoshop uses for the mode inside ActionDescriptors
    /// (`BlnM` enum: `Nrml`, `Mltp`, …), when there is one.
    public var descriptorValue: String? {
        switch self {
        case .passThrough: "passThrough"
        case .normal: "Nrml"
        case .dissolve: "Dslv"
        case .darken: "Drkn"
        case .multiply: "Mltp"
        case .colorBurn: "CBrn"
        case .linearBurn: "linearBurn"
        case .darkerColor: "darkerColor"
        case .lighten: "Lghn"
        case .screen: "Scrn"
        case .colorDodge: "CDdg"
        case .linearDodge: "linearDodge"
        case .lighterColor: "lighterColor"
        case .overlay: "Ovrl"
        case .softLight: "SftL"
        case .hardLight: "HrdL"
        case .vividLight: "vividLight"
        case .linearLight: "linearLight"
        case .pinLight: "pinLight"
        case .hardMix: "hardMix"
        case .difference: "Dfrn"
        case .exclusion: "Xclu"
        case .subtract: "blendSubtraction"
        case .divide: "blendDivide"
        case .hue: "H   "
        case .saturation: "Strt"
        case .color: "Clr "
        case .luminosity: "Lmns"
        case .unknown: nil
        }
    }

    /// The mode a descriptor enumeration value (`BlnM`) names.
    public init?(descriptorValue: String) {
        guard let m = PSDBlendMode.all.first(where: { $0.descriptorValue == descriptorValue }) else { return nil }
        self = m
    }

    public var description: String { key.string }
}
