// Which layer blend modes Photoshop accepts in which document mode and depth.
// Original to this port: measured with Photoshop 27.11 by the port's Photoshop oracle (see
// `PSDBlendMode.allowedModes(mode:depth:isGroup:)`). Photoshop refuses a file whose layers use a
// mode its document cannot have, and raises a modal for pass-through on a non-group record.

extension PSDBlendMode {
    private static let contrastModes: Set<PSDBlendMode> = [.overlay, .softLight, .hardLight, .vividLight, .linearLight, .pinLight, .hardMix]
    /// RGB 32-bit: 12 excluded, 15 allowed.
    private static let excluded32: Set<PSDBlendMode> = contrastModes.union([.colorBurn, .linearBurn, .screen, .colorDodge, .exclusion])
    /// Grayscale 8/16: the colour-only modes, 6 excluded, 21 allowed.
    private static let excludedGray: Set<PSDBlendMode> = [.darkerColor, .lighterColor, .hue, .saturation, .color, .luminosity]
    /// Lab 8/16: 8 excluded, 19 allowed.
    private static let excludedLab: Set<PSDBlendMode> = [.darken, .colorBurn, .lighten, .colorDodge, .difference, .exclusion, .subtract, .divide]

    /// The 27 layer modes (every known mode but pass-through).
    private static let layerModes: [PSDBlendMode] = all.filter { $0 != .passThrough }

    /// Whether Photoshop's table covers this document mode and depth.
    public static func blendTableIsMeasured(mode: PSDColorMode, depth: UInt16) -> Bool {
        switch (mode, depth) {
        case (.rgb, 8), (.rgb, 16), (.rgb, 32), (.grayscale, 8), (.grayscale, 16), (.grayscale, 32),
             (.cmyk, 8), (.cmyk, 16), (.lab, 8), (.lab, 16): true
        case (.bitmap, _), (.indexed, _), (.multichannel, _): true
        default: false
        }
    }

    /// The blend modes Photoshop accepts on a layer (`isGroup == false`) or a group record in a
    /// document of `mode` and `depth`, in `all` order.
    ///
    /// Measured with **Photoshop 27.11.0 on 2026-10-12** by a new-document probe: for each mode and
    /// depth, a new document got a layer and a group, and each mode was set on both. The table gave
    /// 0 false positives on 153 Photoshop-authored files, the 36 Unity corpus files and 151 fixture
    /// files.
    ///
    /// - RGB and CMYK at 8/16 bits: all 27 layer modes.
    /// - RGB at 32 bits: 15 modes. Color Burn, Linear Burn, Screen, Color Dodge, Overlay,
    ///   Soft/Hard/Vivid/Linear/Pin Light, Hard Mix and Exclusion are excluded.
    /// - Grayscale at 8/16 bits: 21 modes. Darker Color, Lighter Color, Hue, Saturation, Color and
    ///   Luminosity are excluded.
    /// - Grayscale at 32 bits: 9 modes (`norm diss dark mul  lite lddg diff fsub fdiv`).
    /// - Lab at 8/16 bits: 19 modes. Darken, Color Burn, Lighten, Color Dodge, Difference,
    ///   Exclusion, Subtract and Divide are excluded.
    /// - Pass-through: valid only on groups, at every mode and depth. Otherwise groups follow the
    ///   same set as layers.
    /// - Bitmap, Indexed and Multichannel: no modes, since those documents have no layers.
    ///
    /// Combinations Photoshop was not measured in (Duotone, and depths a mode does not have, such as
    /// CMYK or Lab at 32 bits) are treated as unconstrained: every layer mode, plus pass-through on
    /// groups. See `blendTableIsMeasured(mode:depth:)`. Unknown keys are never allowed.
    public static func allowedModes(mode: PSDColorMode, depth: UInt16, isGroup: Bool = false) -> [PSDBlendMode] {
        let excluded: Set<PSDBlendMode>
        switch (mode, depth) {
        case (.bitmap, _), (.indexed, _), (.multichannel, _): return []
        case (.rgb, 32): excluded = excluded32
        case (.grayscale, 8), (.grayscale, 16): excluded = excludedGray
        case (.grayscale, 32): excluded = excluded32.union(excludedGray)
        case (.lab, 8), (.lab, 16): excluded = excludedLab
        default: excluded = []
        }
        return (isGroup ? all : layerModes).filter { !excluded.contains($0) }
    }

    /// Whether Photoshop accepts `blend` on a layer (`isGroup == false`) or a group record in a
    /// document of `mode` and `depth` (the table of `allowedModes(mode:depth:isGroup:)`).
    public static func isAllowed(_ blend: PSDBlendMode, mode: PSDColorMode, depth: UInt16, isGroup: Bool) -> Bool {
        if case .unknown = blend { return false }
        return allowedModes(mode: mode, depth: depth, isGroup: isGroup).contains(blend)
    }

    /// The closest mode Photoshop accepts, for writers that substitute instead of refusing.
    /// `blend` itself when allowed. Otherwise the first allowed candidate of its family:
    ///
    /// - Darken family: Darken ↔ Darker Color, Color Burn ↔ Linear Burn, then Multiply.
    /// - Lighten family: Lighten ↔ Lighter Color, Screen / Color Dodge → Linear Dodge, then Screen.
    /// - Contrast family: Overlay ↔ Soft Light.
    /// - Difference ↔ Exclusion, and Subtract → Difference.
    /// - Otherwise Normal. That covers pass-through on a layer, the contrast modes at 32 bits, the
    ///   colour modes in Grayscale, and unknown keys.
    ///
    /// Normal is allowed in every measured document with layers.
    public static func nearestAllowed(_ blend: PSDBlendMode, mode: PSDColorMode, depth: UInt16, isGroup: Bool) -> PSDBlendMode {
        if isAllowed(blend, mode: mode, depth: depth, isGroup: isGroup) { return blend }
        let candidates: [PSDBlendMode]
        switch blend {
        case .darken: candidates = [.darkerColor, .multiply]
        case .darkerColor: candidates = [.darken, .multiply]
        case .colorBurn: candidates = [.linearBurn, .multiply]
        case .linearBurn: candidates = [.colorBurn, .multiply]
        case .lighten: candidates = [.lighterColor, .screen, .linearDodge]
        case .lighterColor: candidates = [.lighten, .screen, .linearDodge]
        case .screen: candidates = [.linearDodge, .lighten]
        case .colorDodge: candidates = [.linearDodge, .screen]
        case .linearDodge: candidates = [.screen]
        case .overlay, .hardLight, .vividLight, .linearLight, .pinLight, .hardMix: candidates = [.softLight, .overlay]
        case .softLight: candidates = [.overlay]
        case .difference: candidates = [.exclusion]
        case .exclusion, .subtract: candidates = [.difference]
        default: candidates = []
        }
        return candidates.first { isAllowed($0, mode: mode, depth: depth, isGroup: isGroup) } ?? .normal
    }
}
