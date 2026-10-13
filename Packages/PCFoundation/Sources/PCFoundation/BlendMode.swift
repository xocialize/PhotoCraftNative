// Photoshop and Paint.NET blend modes: the scalar CPU reference the Metal kernels must match.
// Port of photocraft-color (crates/color/src/blend.rs), MIT OR Apache-2.0, © ArtCraft Team and the
// PhotoCraft contributors. Formulas follow ISO 32000-2 / W3C Compositing with Photoshop's variants
// (Soft Light, Hard Mix, Darker/Lighter Color, Linear Burn/Dodge, Vivid/Linear/Pin Light,
// Subtract, Divide).
//
import Foundation
import simd

// The raw value is the shader index: Metal kernels switch on the same numbers
// (Shaders/PCBlend.metal), so never reorder cases.

public enum BlendMode: UInt32, CaseIterable, Sendable, Codable {
    /// Groups only: children blend directly into the group's backdrop.
    case passThrough = 0
    case normal, dissolve
    case darken, multiply, colorBurn, linearBurn, darkerColor
    case lighten, screen, colorDodge, linearDodge, lighterColor
    case overlay, softLight, hardLight, vividLight, linearLight, pinLight, hardMix
    case difference, exclusion, subtract, divide
    case hue, saturation, color, luminosity
    // Paint.NET modes without a Photoshop equivalent.
    case reflect, glow, negation, xor, paintNetColorBurn, paintNetColorDodge

    public static let paintNetModes: [BlendMode] = [.reflect, .glow, .negation, .xor, .paintNetColorBurn, .paintNetColorDodge]

    /// Photoshop modes except Pass Through, in Photoshop's menu order.
    public static let layerModes: [BlendMode] = [
        .normal, .dissolve, .darken, .multiply, .colorBurn, .linearBurn, .darkerColor,
        .lighten, .screen, .colorDodge, .linearDodge, .lighterColor,
        .overlay, .softLight, .hardLight, .vividLight, .linearLight, .pinLight, .hardMix,
        .difference, .exclusion, .subtract, .divide, .hue, .saturation, .color, .luminosity,
    ]

    /// Every editable layer mode, Paint.NET modes after Photoshop's.
    public static var allLayerModes: [BlendMode] { layerModes + paintNetModes }

    public var hasPSDEquivalent: Bool { !BlendMode.paintNetModes.contains(self) }

    public var isSeparable: Bool {
        switch self {
        case .hue, .saturation, .color, .luminosity, .darkerColor, .lighterColor: false
        default: true
        }
    }

    public var label: String {
        switch self {
        case .passThrough: "Pass Through"
        case .normal: "Normal"
        case .dissolve: "Dissolve"
        case .darken: "Darken"
        case .multiply: "Multiply"
        case .colorBurn: "Color Burn"
        case .linearBurn: "Linear Burn"
        case .darkerColor: "Darker Color"
        case .lighten: "Lighten"
        case .screen: "Screen"
        case .colorDodge: "Color Dodge"
        case .linearDodge: "Linear Dodge (Add)"
        case .lighterColor: "Lighter Color"
        case .overlay: "Overlay"
        case .softLight: "Soft Light"
        case .hardLight: "Hard Light"
        case .vividLight: "Vivid Light"
        case .linearLight: "Linear Light"
        case .pinLight: "Pin Light"
        case .hardMix: "Hard Mix"
        case .difference: "Difference"
        case .exclusion: "Exclusion"
        case .subtract: "Subtract"
        case .divide: "Divide"
        case .hue: "Hue"
        case .saturation: "Saturation"
        case .color: "Color"
        case .luminosity: "Luminosity"
        case .reflect: "Reflect"
        case .glow: "Glow"
        case .negation: "Negation"
        case .xor: "XOR"
        case .paintNetColorBurn: "Color Burn (Paint.NET)"
        case .paintNetColorDodge: "Color Dodge (Paint.NET)"
        }
    }

    /// PSD four-character blend key. Modes without an equivalent fall back to `norm`; exporters
    /// must report that loss using `hasPSDEquivalent`.
    public var psdKey: String {
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
        case .reflect, .glow, .negation, .xor, .paintNetColorBurn, .paintNetColorDodge: "norm"
        }
    }

    public init?(psdKey: String) {
        guard let m = ([BlendMode.passThrough] + BlendMode.layerModes).first(where: { $0.psdKey == psdKey }) else { return nil }
        self = m
    }
}

// MARK: - Scalar reference math

public enum Blend {
    /// Separable per-channel blend `B(cb, cs)`.
    @inlinable public static func channel(_ mode: BlendMode, _ cb: Float, _ cs: Float) -> Float {
        channel(mode, cb, cs, hi: 1)
    }

    /// `channel` for 32-bit float documents: Linear Dodge (Add) and Divide don't clip at 1 there.
    @inlinable public static func channelHDR(_ mode: BlendMode, _ cb: Float, _ cs: Float) -> Float {
        channel(mode, cb, cs, hi: .greatestFiniteMagnitude)
    }

    @usableFromInline static func channel(_ mode: BlendMode, _ cb: Float, _ cs: Float, hi: Float) -> Float {
        switch mode {
        case .normal, .dissolve, .passThrough: return cs
        case .darken: return min(cb, cs)
        case .multiply: return cb * cs
        case .colorBurn: return colorBurn(cb, cs)
        case .linearBurn: return max(cb + cs - 1, 0)
        case .lighten: return max(cb, cs)
        case .screen: return cb + cs - cb * cs
        case .colorDodge: return colorDodge(cb, cs)
        case .linearDodge: return min(cb + cs, hi)
        case .overlay: return hardLight(cs, cb)
        case .softLight: return softLightPS(cb, cs)
        case .hardLight: return hardLight(cb, cs)
        case .vividLight:
            if cs <= 0 { return 0 }
            if cs >= 1 { return 1 }
            return cs <= 0.5 ? colorBurn(cb, 2 * cs) : colorDodge(cb, 2 * (cs - 0.5))
        case .linearLight: return min(max(cb + 2 * cs - 1, 0), 1)
        case .pinLight: return cs <= 0.5 ? min(cb, 2 * cs) : max(cb, 2 * cs - 1)
        case .hardMix: return vividLightHardMix(cb, cs) >= 0.5 - 1e-6 ? 1 : 0
        case .difference: return abs(cb - cs)
        case .exclusion: return cb + cs - 2 * cb * cs
        case .subtract: return hi > 1 ? cb - cs : max(cb - cs, 0)   // 32-bit: unclipped (Photoshop)
        case .divide:
            if cs <= 0 { return cb <= 0 ? 0 : 1 }
            return min(cb / cs, hi)
        case .reflect: return reflect(cb, cs)
        case .glow: return reflect(cs, cb)
        case .negation: return 1 - abs(1 - cb - cs)
        case .xor:
            // Paint.NET's XOR is defined on 8-bit channels even in a float compositor.
            let b = UInt8((min(max(cb, 0), 1) * 255).rounded())
            let s = UInt8((min(max(cs, 0), 1) * 255).rounded())
            return Float(b ^ s) / 255
        case .paintNetColorBurn: return cs <= 0 ? 0 : max(1 - (1 - cb) / cs, 0)
        case .paintNetColorDodge: return cs >= 1 ? 1 : min(cb / (1 - cs), 1)
        case .darkerColor, .lighterColor, .hue, .saturation, .color, .luminosity: return cs
        }
    }

    @usableFromInline static func reflect(_ cb: Float, _ cs: Float) -> Float {
        cs >= 1 ? 1 : min(cb * cb / (1 - cs), 1)
    }

    @usableFromInline static func vividLightHardMix(_ cb: Float, _ cs: Float) -> Float {
        let edge: Float = 1e-4
        if cs <= 0.5 {
            if cb >= 1 - edge { return 1 }
            if cs <= 0 { return 0 }
            return 1 - min((1 - cb) / (2 * cs), 1)
        }
        if cb <= edge { return 0 }
        if cs >= 1 { return 1 }
        return min(cb / (2 * (1 - cs)), 1)
    }

    @usableFromInline static func colorBurn(_ cb: Float, _ cs: Float) -> Float {
        if cb >= 1 { return 1 }
        if cs <= 0 { return 0 }
        return 1 - min((1 - cb) / cs, 1)
    }

    @usableFromInline static func colorDodge(_ cb: Float, _ cs: Float) -> Float {
        if cb <= 0 { return 0 }
        if cs >= 1 { return 1 }
        return min(cb / (1 - cs), 1)
    }

    @usableFromInline static func hardLight(_ cb: Float, _ cs: Float) -> Float {
        if cs <= 0.5 { return cb * 2 * cs }
        let s = 2 * cs - 1
        return cb + s - cb * s
    }

    /// Soft Light as Photoshop 27 renders it: the W3C definition, whose upper half uses
    /// D(cb) = ((16cb − 12)cb + 4)cb below cb = ¼ and √cb above. photocraft used √cb throughout,
    /// which is 4–10 levels off for dark backdrops (measured by PCRender on Photoshop's own
    /// soft-light band files at 8/16 bits, CMYK and Lab: the W3C curve fits within 0.33 level).
    @usableFromInline static func softLightPS(_ cb: Float, _ cs: Float) -> Float {
        if cs <= 0.5 { return cb - (1 - 2 * cs) * cb * (1 - cb) }
        let d = cb <= 0.25 ? ((16 * cb - 12) * cb + 4) * cb : sqrtf(max(cb, 0))
        return cb + (2 * cs - 1) * (d - cb)
    }

    // MARK: Non-separable (W3C Compositing Level 1)

    @inlinable public static func lum(_ c: SIMD3<Float>) -> Float { 0.3 * c.x + 0.59 * c.y + 0.11 * c.z }

    /// ClipColor at `top` (1, or Float.max in 32-bit documents). Colours whose luminosity is itself
    /// out of range become their grey (photocraft's fix for CPU/GPU divergence).
    static func clipColor(_ c: SIMD3<Float>, top: Float) -> SIMD3<Float> {
        let l = lum(c)
        let n = c.min(), x = c.max()
        var out = c
        if n < 0 {
            let d = l - n
            for i in 0..<3 { out[i] = (l > 0 && d > 0) ? l + (out[i] - l) * l / d : l }
        }
        if x > top {
            let d = x - l
            for i in 0..<3 { out[i] = (l < top && d > 0) ? l + (out[i] - l) * (top - l) / d : l }
        }
        return out
    }

    /// `c` with its luminosity moved to `l`, clipped back into gamut (SetLum + ClipColor).
    public static func setLum(_ c: SIMD3<Float>, _ l: Float, top: Float = 1) -> SIMD3<Float> {
        clipColor(c + (l - lum(c)), top: top)
    }

    static func sat(_ c: SIMD3<Float>) -> Float { c.max() - c.min() }

    static func setSat(_ c: SIMD3<Float>, _ s: Float) -> SIMD3<Float> {
        var idx = [0, 1, 2]
        idx.sort { c[$0] < c[$1] }
        let (imin, imid, imax) = (idx[0], idx[1], idx[2])
        var out = SIMD3<Float>(repeating: 0)
        if c[imax] > c[imin] {
            out[imid] = (c[imid] - c[imin]) * s / (c[imax] - c[imin])
            out[imax] = s
        }
        out[imin] = 0
        return out
    }

    /// `B(Cb, Cs)` on an RGB triple, including the non-separable modes, clipping at `top`.
    public static func rgb(_ mode: BlendMode, _ cb: SIMD3<Float>, _ cs: SIMD3<Float>, top: Float = 1) -> SIMD3<Float> {
        switch mode {
        case .hue: return setLum(setSat(cs, sat(cb)), lum(cb), top: top)
        case .saturation: return setLum(setSat(cb, sat(cs)), lum(cb), top: top)
        case .color: return setLum(cs, lum(cb), top: top)
        case .luminosity: return setLum(cb, lum(cs), top: top)
        case .darkerColor: return lum(cs) < lum(cb) ? cs : cb
        case .lighterColor: return lum(cs) > lum(cb) ? cs : cb
        default: return SIMD3(channel(mode, cb.x, cs.x), channel(mode, cb.y, cs.y), channel(mode, cb.z, cs.z))
        }
    }

    /// `rgb` for 32-bit float documents: values above 1 survive, Subtract is unclipped, and the
    /// non-separable modes skip ClipColor entirely — as Photoshop renders 32-bit documents
    /// (measured by PCRender on Photoshop's blend-bands-rgb-32 file).
    public static func rgbHDR(_ mode: BlendMode, _ cb: SIMD3<Float>, _ cs: SIMD3<Float>) -> SIMD3<Float> {
        switch mode {
        case .hue: return setSat(cs, sat(cb)) + (lum(cb) - lum(setSat(cs, sat(cb))))
        case .saturation: return setSat(cb, sat(cs)) + (lum(cb) - lum(setSat(cb, sat(cs))))
        case .color: return cs + (lum(cb) - lum(cs))
        case .luminosity: return cb + (lum(cs) - lum(cb))
        case .darkerColor, .lighterColor: return rgb(mode, cb, cs)
        default: return SIMD3(channelHDR(mode, cb.x, cs.x), channelHDR(mode, cb.y, cs.y), channelHDR(mode, cb.z, cs.z))
        }
    }

    /// Composites a straight-alpha source over a straight-alpha backdrop (W3C/PDF general formula):
    /// `αo = αs + αb(1−αs)`, `αo·Co = (1−αs)·αb·Cb + (1−αb)·αs·Cs + αs·αb·B(Cb,Cs)`.
    /// Dissolve must be resolved by the caller before calling.
    public static func composite(_ mode: BlendMode, backdrop: SIMD4<Float>, source: SIMD4<Float>, opacity: Float) -> SIMD4<Float> {
        let ab = backdrop.w
        let as_ = source.w * opacity
        if as_ <= 0 { return backdrop }
        let cb = SIMD3(backdrop.x, backdrop.y, backdrop.z)
        let cs = SIMD3(source.x, source.y, source.z)
        let b = rgb(mode, cb, cs)
        let ao = as_ + ab * (1 - as_)
        if ao <= 0 { return .zero }
        let premul = (1 - as_) * ab * cb + (1 - ab) * as_ * cs + as_ * ab * b
        return SIMD4(premul / ao, ao)
    }
}
