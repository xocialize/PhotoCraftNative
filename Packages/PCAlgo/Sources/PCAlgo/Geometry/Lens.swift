// Port of photocraft-algo (crates/algo/src/lens.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Filter › Lens Correction: geometric distortion, lateral chromatic aberration, vignetting and
// perspective / rotation / scale, with Photoshop's edge modes.
//
// * Distortion: Brown–Conrady radial terms (Brown 1966; Conrady 1919): an output point at
//   normalised radius r (1 = half the frame diagonal) samples the source at r·(1 + k1·r² + k2·r⁴),
//   plus the tangential p1, p2 terms; Remove Distortion adds to k1.
// * Chromatic aberration (lateral): red and blue are scaled radially relative to green.
// * Vignetting: the profile's 1 + v1·r² + v2·r⁴ + v3·r⁶ falloff is divided out, then the Vignette
//   Amount / Midpoint exposure change ramps in from the midpoint.
// * Transform: vertical / horizontal keystone about the frame centre, then angle and scale.
//
// The geometry is an inverse map per output pixel (Catmull-Rom, premultiplied with alpha) over
// 128-px output tiles; each tile reads the source window its samples span (clamped to the frame,
// which also extends the frame's edge). The CPU maps in f64 as photocraft does; the Metal path
// maps in f32 (positions within ~1e-4 px), marks every tile's sample bounds with atomics, then
// samples. Generic profiles stand in for proprietary manufacturer data (`Lens.genericProfile`).

import Foundation
import Metal
import PCFoundation

/// What fills the output where the corrected image doesn't reach (photocraft `lens::EdgeMode`;
/// serde: `"extension"`, `"transparency"`, `{"color": [r, g, b, a]}`).
public enum LensEdgeMode: Hashable, Sendable, Codable {
    /// Repeat the edge pixels (photocraft `Extension`).
    case edgeExtension
    case transparency
    /// A solid colour, straight sRGB RGBA, converted to the document's model.
    case color(SIMD4<Float>)

    public static let `default` = LensEdgeMode.transparency

    enum ColorKey: String, CodingKey { case color }

    public init(from decoder: any Decoder) throws {
        if let s = try? decoder.singleValueContainer().decode(String.self) {
            switch s {
            case "extension": self = .edgeExtension
            case "transparency": self = .transparency
            default: throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "unknown edge mode \(s)"))
            }
            return
        }
        let c = try decoder.container(keyedBy: ColorKey.self)
        let v = try c.decode([Float].self, forKey: .color)
        guard v.count == 4 else { throw DecodingError.dataCorruptedError(forKey: .color, in: c, debugDescription: "colour needs 4 values") }
        self = .color(SIMD4(v[0], v[1], v[2], v[3]))
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .edgeExtension: var c = encoder.singleValueContainer(); try c.encode("extension")
        case .transparency: var c = encoder.singleValueContainer(); try c.encode("transparency")
        case .color(let v):
            var c = encoder.container(keyedBy: ColorKey.self)
            try c.encode([v.x, v.y, v.z, v.w], forKey: .color)
        }
    }
}

/// A lens profile: distortion, vignetting and lateral CA coefficients (photocraft `LensProfile`;
/// serde names are photocraft's snake_case field names).
public struct LensProfile: Hashable, Sendable, Codable {
    public var name: String
    public var k1: Double
    public var k2: Double
    public var p1: Double
    public var p2: Double
    /// Vignetting falloff `1 + v1 r² + v2 r⁴ + v3 r⁶`.
    public var vignette: [Double]
    /// Radial scale of red / blue relative to green (`1 + ca`).
    public var caRed: Double
    public var caBlue: Double

    enum CodingKeys: String, CodingKey {
        case name, k1, k2, p1, p2, vignette
        case caRed = "ca_red"
        case caBlue = "ca_blue"
    }

    public init(name: String = "", k1: Double = 0, k2: Double = 0, p1: Double = 0, p2: Double = 0, vignette: [Double] = [0, 0, 0],
                caRed: Double = 0, caBlue: Double = 0) {
        precondition(vignette.count == 3, "vignette has three coefficients")
        self.name = name; self.k1 = k1; self.k2 = k2; self.p1 = p1; self.p2 = p2; self.vignette = vignette
        self.caRed = caRed; self.caBlue = caBlue
    }

    /// Every field is required, as photocraft's derive; `vignette` must hold three values (`[f64; 3]`).
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let v = try c.decode([Double].self, forKey: .vignette)
        guard v.count == 3 else { throw DecodingError.dataCorruptedError(forKey: .vignette, in: c, debugDescription: "vignette has three coefficients") }
        self.init(name: try c.decode(String.self, forKey: .name), k1: try c.decode(Double.self, forKey: .k1), k2: try c.decode(Double.self, forKey: .k2),
                  p1: try c.decode(Double.self, forKey: .p1), p2: try c.decode(Double.self, forKey: .p2), vignette: v,
                  caRed: try c.decode(Double.self, forKey: .caRed), caBlue: try c.decode(Double.self, forKey: .caBlue))
    }
}

/// Filter › Lens Correction, in Photoshop's dialog units (photocraft `LensCorrection`). As a
/// `Filter` the reference frame is the context's bounds (normally the canvas). Without alpha,
/// Transparency can't be stored in place: the filter then returns photocraft's colour channels
/// (uncovered areas 0); `Lens.correct` adds the alpha channel instead, as photocraft does.
///
/// JSON is photocraft's `filter.lensCorrection` command params — what a stored smart filter holds
/// (engine `lens_cmds::lens_params`; see `init(from:)` / `encode(to:)`).
public struct LensCorrection: Filter, Hashable {
    /// Profile applied first (Auto Correction tab).
    public var profile: LensProfile?
    public var correctDistortion: Bool
    public var correctVignette: Bool
    public var correctCa: Bool
    /// Remove Distortion −100…100.
    public var distortion: Double
    /// Fix Red/Cyan Fringe −100…100.
    public var redCyan: Double
    /// Fix Blue/Yellow Fringe −100…100.
    public var blueYellow: Double
    /// Vignette Amount −100…100 (positive lightens the corners).
    public var vignetteAmount: Double
    /// Vignette Midpoint 0…100.
    public var vignetteMidpoint: Double
    /// Vertical Perspective −100…100.
    public var vertical: Double
    /// Horizontal Perspective −100…100.
    public var horizontal: Double
    /// Angle in degrees (positive turns the image clockwise).
    public var angle: Double
    /// Scale in percent (50…150).
    public var scale: Double
    public var edge: LensEdgeMode
    /// Auto Scale: `scale` becomes the smallest (not below `scale`) at which the corrected image
    /// covers the frame, resolved against the frame each run (engine `lens_params` `autoScale`).
    public var autoScale: Bool

    public init(profile: LensProfile? = nil, correctDistortion: Bool = true, correctVignette: Bool = true, correctCa: Bool = true,
                distortion: Double = 0, redCyan: Double = 0, blueYellow: Double = 0, vignetteAmount: Double = 0, vignetteMidpoint: Double = 50,
                vertical: Double = 0, horizontal: Double = 0, angle: Double = 0, scale: Double = 100, edge: LensEdgeMode = .transparency,
                autoScale: Bool = false) {
        self.profile = profile; self.correctDistortion = correctDistortion; self.correctVignette = correctVignette; self.correctCa = correctCa
        self.distortion = distortion; self.redCyan = redCyan; self.blueYellow = blueYellow; self.vignetteAmount = vignetteAmount
        self.vignetteMidpoint = vignetteMidpoint; self.vertical = vertical; self.horizontal = horizontal; self.angle = angle
        self.scale = scale; self.edge = edge; self.autoScale = autoScale
    }

    /// These settings with Auto Scale resolved for `frame` (`LensMap` does this).
    public func resolved(frame: PixelRect) -> LensCorrection {
        guard autoScale else { return self }
        var l = self
        l.autoScale = false
        l.scale = Lens.autoScale(l, frame: frame)
        return l
    }

    enum CodingKeys: String, CodingKey {
        case profile, focalLength, correctDistortion, correctVignette, correctCA, distortion, redCyan, blueYellow, vignetteAmount
        case vignetteMidpoint, vertical, horizontal, angle, scale, edge, edgeColor, straighten, autoScale
        /// lens::LensCorrection's own serde name (accepted when `correctCA` is absent).
        case correctCa
    }

    /// Decodes photocraft's engine params as `lens_cmds::lens_params` reads them (apart from EXIF:
    /// a smart filter is re-applied without it, so `"auto"` uses `focalLength` or no profile):
    ///
    /// * `profile`: `"none"` / `""` (default) → none; `"generic"` → `Lens.genericProfile(focalLength,
    ///   or 50 when ≤ 0)`; `"auto"` → the generic profile for `focalLength` when > 0, else none;
    ///   another name throws. A profile object (`LensProfile` serde) is accepted too.
    /// * `correctDistortion`, `correctVignette`, `correctCA` (or `correctCa`): default true.
    /// * Sliders default to 0 (`vignetteMidpoint` 50, `scale` 100) and are clamped to the dialog
    ///   ranges (−100…100, midpoint 0…100, scale 50…150; `angle` unclamped). A number or flag of
    ///   the wrong type takes the default, as the engine's `num` / `flag`.
    /// * `edge`: `"transparency"` (default), `"edgeExtension"` / `"extension"`, `"black"`, `"white"`,
    ///   `"color"` / `"background"` with `edgeColor` (`[r, g, b, a?]` 0…1 or `"#rrggbb(aa)"`, default
    ///   black); another name throws. `{"color": [r, g, b, a]}` (`LensEdgeMode` serde) is accepted too.
    /// * `straighten: [[x0, y0], [x1, y1]]` adds `Lens.straightenAngle` to `angle`; `autoScale` sets
    ///   `autoScale` (resolved per frame).
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func num(_ k: CodingKeys, _ d: Double) -> Double {
            guard let v = (try? c.decodeIfPresent(Double.self, forKey: k)) ?? nil, v.isFinite else { return d }
            return v
        }
        func flag(_ k: CodingKeys, _ d: Bool) -> Bool { ((try? c.decodeIfPresent(Bool.self, forKey: k)) ?? nil) ?? d }
        func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(max(v, lo), hi) }
        correctDistortion = flag(.correctDistortion, true)
        correctVignette = flag(.correctVignette, true)
        correctCa = c.contains(.correctCA) ? flag(.correctCA, true) : flag(.correctCa, true)
        distortion = clamp(num(.distortion, 0), -100, 100)
        redCyan = clamp(num(.redCyan, 0), -100, 100)
        blueYellow = clamp(num(.blueYellow, 0), -100, 100)
        vignetteAmount = clamp(num(.vignetteAmount, 0), -100, 100)
        vignetteMidpoint = clamp(num(.vignetteMidpoint, 50), 0, 100)
        vertical = clamp(num(.vertical, 0), -100, 100)
        horizontal = clamp(num(.horizontal, 0), -100, 100)
        angle = num(.angle, 0)
        scale = clamp(num(.scale, 100), 50, 150)

        if let name = (try? c.decodeIfPresent(String.self, forKey: .edge)) ?? nil {
            switch name {
            case "transparency": edge = .transparency
            case "edgeExtension", "extension": edge = .edgeExtension
            case "black": edge = .color(SIMD4(0, 0, 0, 1))
            case "white": edge = .color(SIMD4(1, 1, 1, 1))
            case "background", "color": edge = .color(Self.edgeColor(c))
            default:
                throw DecodingError.dataCorruptedError(forKey: .edge, in: c, debugDescription: "unknown edge `\(name)` (transparency|edgeExtension|black|white|color)")
            }
        } else {
            edge = ((try? c.decodeIfPresent(LensEdgeMode.self, forKey: .edge)) ?? nil) ?? .transparency
        }

        let focal = num(.focalLength, 0)
        if let name = (try? c.decodeIfPresent(String.self, forKey: .profile)) ?? nil {
            switch name {
            case "none", "": profile = nil
            case "generic": profile = Lens.genericProfile(focal35mm: focal > 0 ? focal : 50)
            case "auto": profile = focal > 0 ? Lens.genericProfile(focal35mm: focal) : nil
            default:
                throw DecodingError.dataCorruptedError(forKey: .profile, in: c, debugDescription: "unknown profile `\(name)` (none|auto|generic)")
            }
        } else if (try? c.nestedContainer(keyedBy: LensProfile.CodingKeys.self, forKey: .profile)) != nil {
            profile = try c.decode(LensProfile.self, forKey: .profile)
        } else {
            profile = nil
        }

        if (try? c.nestedUnkeyedContainer(forKey: .straighten)) != nil {
            guard let line = try? c.decode([[Double]].self, forKey: .straighten), line.count >= 2, line[0].count >= 2, line[1].count >= 2 else {
                throw DecodingError.dataCorruptedError(forKey: .straighten, in: c, debugDescription: "`straighten` is [[x0,y0],[x1,y1]]")
            }
            angle += Lens.straightenAngle(SIMD2(line[0][0], line[0][1]), SIMD2(line[1][0], line[1][1]))
        }
        autoScale = flag(.autoScale, false)
    }

    /// photocraft engine `color_param(p, "edgeColor", black)`: an array of at least three numbers
    /// (others read 0; alpha defaults to 1) or a hex string; anything else is black.
    static func edgeColor(_ c: KeyedDecodingContainer<CodingKeys>) -> SIMD4<Float> {
        let black = SIMD4<Float>(0, 0, 0, 1)
        if var u = try? c.nestedUnkeyedContainer(forKey: .edgeColor) {
            struct Skip: Decodable { init(from decoder: any Decoder) throws {} }
            var v: [Float] = []
            while !u.isAtEnd {
                if let x = try? u.decode(Double.self) { v.append(Float(x)) } else { _ = try? u.decode(Skip.self); v.append(0) }
            }
            return v.count >= 3 ? SIMD4(v[0], v[1], v[2], v.count > 3 ? v[3] : 1) : black
        }
        guard let s = (try? c.decodeIfPresent(String.self, forKey: .edgeColor)) ?? nil else { return black }
        let h = Array(s.drop { $0 == "#" }.utf8)
        guard h.count == 6 || h.count == 8 else { return black }
        var v: [Float] = []
        for i in stride(from: 0, to: h.count, by: 2) {
            guard let b = UInt8(String(decoding: h[i..<(i + 2)], as: UTF8.self), radix: 16) else { return black }
            v.append(Float(b) / 255)
        }
        return SIMD4(v[0], v[1], v[2], v.count > 3 ? v[3] : 1)
    }

    /// The focal length `profile` is the generic profile of, if it is one (exactly).
    static func genericFocal(_ p: LensProfile) -> Double? {
        let prefix = "Generic Lens (", suffix = " mm equivalent)"
        guard p.name.hasPrefix(prefix), p.name.hasSuffix(suffix),
              let f = Double(p.name.dropFirst(prefix.count).dropLast(suffix.count)), f.isFinite, f > 0,
              Lens.genericProfile(focal35mm: f) == p else { return nil }
        return f
    }

    /// Encodes the engine params shape, which `init(from:)` reads back exactly (and photocraft's
    /// engine reads too): `profile` `"none"` or `"generic"` + `focalLength`, a profile object for
    /// any other profile (photocraft's engine would take that as none); `correctCA`; the sliders;
    /// `edge` `"transparency"` / `"edgeExtension"` / `"color"` + `edgeColor` `[r, g, b, a]`;
    /// `autoScale: true` only when set.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if let p = profile {
            if let f = Self.genericFocal(p) {
                try c.encode("generic", forKey: .profile)
                try c.encode(f, forKey: .focalLength)
            } else {
                try c.encode(p, forKey: .profile)
            }
        } else {
            try c.encode("none", forKey: .profile)
        }
        try c.encode(correctDistortion, forKey: .correctDistortion)
        try c.encode(correctVignette, forKey: .correctVignette)
        try c.encode(correctCa, forKey: .correctCA)
        try c.encode(distortion, forKey: .distortion)
        try c.encode(redCyan, forKey: .redCyan)
        try c.encode(blueYellow, forKey: .blueYellow)
        try c.encode(vignetteAmount, forKey: .vignetteAmount)
        try c.encode(vignetteMidpoint, forKey: .vignetteMidpoint)
        try c.encode(vertical, forKey: .vertical)
        try c.encode(horizontal, forKey: .horizontal)
        try c.encode(angle, forKey: .angle)
        try c.encode(scale, forKey: .scale)
        switch edge {
        case .transparency: try c.encode("transparency", forKey: .edge)
        case .edgeExtension: try c.encode("edgeExtension", forKey: .edge)
        case .color(let v):
            try c.encode("color", forKey: .edge)
            try c.encode([v.x, v.y, v.z, v.w], forKey: .edgeColor)
        }
        if autoScale { try c.encode(true, forKey: .autoScale) }
    }

    public var label: String { "Lens Correction" }
    public func halo(bounds: PixelRect) -> Halo { .bounds }

    func kit(_ ctx: FilterContext, channels n: Int, out: PixelRect) -> GeometryKit.LensFilter {
        let frame = ctx.bounds
        let spec = GeometryKit.RemapSpec(ctx: ctx, channels: n, srcAlpha: ctx.alpha, edge: edge, clip: false, frame: frame,
                                         tileOrigin: SIMD2(frame.x0, frame.y0), tileClip: frame.union(out))
        return GeometryKit.LensFilter(map: LensMap(self, frame: frame), spec: spec)
    }

    public func cpu(_ src: FloatImage, out: PixelRect, ctx: FilterContext) -> FloatImage {
        kit(ctx, channels: src.channels, out: out).cpu(src, out: out, ctx: ctx)
    }

    public func encodeGPU(_ pass: GPUPass) throws {
        let n = Int(pass.frame.colorChannels) + (pass.ctx.alpha ? 1 : 0)
        try kit(pass.ctx, channels: n, out: pass.out).encodeGPU(pass)
    }
}

/// Where an output pixel samples the source: green (and alpha / non-RGB channels) at `p`, red at
/// `pr`, blue at `pb`; the colour is then multiplied by `gain` (photocraft `lens::Sample`).
public struct LensSample: Hashable, Sendable {
    public var p: SIMD2<Double>
    public var pr: SIMD2<Double>
    public var pb: SIMD2<Double>
    public var gain: Float
    public init(p: SIMD2<Double>, pr: SIMD2<Double>, pb: SIMD2<Double>, gain: Float) { self.p = p; self.pr = pr; self.pb = pb; self.gain = gain }
}

/// The inverse map of a `LensCorrection` over a frame (photocraft `LensMap`).
public struct LensMap: Sendable, Codable, Equatable {
    var c: SIMD2<Double>
    /// Half diagonal (radius normaliser).
    var r: Double
    var k1: Double
    var k2: Double
    var p1: Double
    var p2: Double
    var caR: Double
    var caB: Double
    var vigProfile: SIMD3<Double>
    var vigAmount: Double
    var vigMid: Double
    /// Inverse keystone (normalised coordinates), row-major.
    var hinv: [Double]
    var rotS: Double
    var rotC: Double
    var scale: Double

    public init(_ settings: LensCorrection, frame: PixelRect) {
        let lc = settings.resolved(frame: frame)
        c = SIMD2(Double(frame.x0 + frame.x1) / 2, Double(frame.y0 + frame.y1) / 2)
        r = max(hypot(Double(frame.width), Double(frame.height)), 2) / 2
        let prof = lc.profile ?? LensProfile()
        let (pk1, pk2, pp1, pp2) = lc.correctDistortion ? (prof.k1, prof.k2, prof.p1, prof.p2) : (0, 0, 0, 0)
        // Keystone x' = x / (1 + h x + g y), y' = y / (1 + h x + g y) (normalised by r).
        let g = -lc.vertical / 100 * 0.5
        let h = -lc.horizontal / 100 * 0.5
        // Inverse of [[1,0,0],[0,1,0],[h,g,1]] is [[1,0,0],[0,1,0],[−h,−g,1]].
        hinv = [1, 0, 0, 0, 1, 0, -h, -g, 1]
        let a = lc.angle * (Double.pi / 180)
        k1 = pk1 - lc.distortion / 100 * 0.25
        k2 = pk2
        p1 = pp1
        p2 = pp2
        caR = (lc.correctCa ? prof.caRed : 0) - lc.redCyan * 4e-5
        caB = (lc.correctCa ? prof.caBlue : 0) - lc.blueYellow * 4e-5
        vigProfile = lc.correctVignette ? SIMD3(prof.vignette[0], prof.vignette[1], prof.vignette[2]) : .zero
        vigAmount = lc.vignetteAmount / 100
        vigMid = GeometryKit.clampR(lc.vignetteMidpoint, 0, 100) / 100
        rotS = sin(a)
        rotC = cos(a)
        scale = GeometryKit.clampR(lc.scale / 100, 0.05, 20)
    }

    /// Output px → where to sample (nil when the keystone sends it to infinity).
    public func sample(_ x: Double, _ y: Double) -> LensSample? {
        // Undo scale and rotation (about the centre).
        let dx = (x - c.x) / scale, dy = (y - c.y) / scale
        let s = rotS, co = rotC
        let rx = co * dx + s * dy, ry = -s * dx + co * dy
        // Undo the keystone.
        let nx = rx / r, ny = ry / r
        let w = hinv[6] * nx + hinv[7] * ny + hinv[8]
        if w <= 0.05 { return nil }
        let ux = nx / w, uy = ny / w
        // Lens distortion (Brown–Conrady).
        let r2 = ux * ux + uy * uy
        let radial = 1.0 + k1 * r2 + k2 * r2 * r2
        let sx = ux * radial + 2.0 * p1 * ux * uy + p2 * (r2 + 2.0 * ux * ux)
        let sy = uy * radial + p1 * (r2 + 2.0 * uy * uy) + 2.0 * p2 * ux * uy
        func toPx(_ k: Double) -> SIMD2<Double> { SIMD2(c.x + sx * k * r, c.y + sy * k * r) }
        // Vignetting on the source radius.
        let rs2 = sx * sx + sy * sy
        let (v1, v2, v3) = (vigProfile.x, vigProfile.y, vigProfile.z)
        let falloff = fmax(1.0 + v1 * rs2 + v2 * rs2 * rs2 + v3 * rs2 * rs2 * rs2, 0.05)
        let start = (1.0 - vigMid) * 0.9
        let t = GeometryKit.clampR((rs2.squareRoot() - start) / (1.0 - start + 1e-9), 0, 1)
        let ramp = t * t * (3.0 - 2.0 * t)
        let gain = pow(2.0, vigAmount * 1.5 * ramp) / falloff
        return LensSample(p: toPx(1), pr: toPx(1 + caR), pb: toPx(1 + caB), gain: Float(gain))
    }

}

/// Lens Correction functions (photocraft `lens.rs`).
public enum Lens {
    /// Generic profile for a 35 mm-equivalent focal length: barrel distortion and strong
    /// vignetting at the wide end, mild pincushion at the long end (photocraft `generic_profile`).
    public static func genericProfile(focal35mm: Double) -> LensProfile {
        // (focal, k1, k2, v1, v2)
        let table: [(Double, Double, Double, Double, Double)] = [
            (12, -0.16, 0.04, -0.60, 0.15),
            (16, -0.11, 0.025, -0.50, 0.12),
            (24, -0.06, 0.012, -0.38, 0.08),
            (35, -0.025, 0.004, -0.28, 0.05),
            (50, 0, 0, -0.22, 0.04),
            (85, 0.012, 0, -0.16, 0.02),
            (200, 0.02, 0, -0.10, 0.01),
        ]
        let f = GeometryKit.clampR(focal35mm, table[0].0, table[6].0)
        let k = (0..<6).first { f <= table[$0 + 1].0 } ?? 5
        let a = table[k], b = table[k + 1]
        // Interpolate on log focal length.
        let t = (log(f) - log(a.0)) / (log(b.0) - log(a.0))
        func l(_ x: Double, _ y: Double) -> Double { x + (y - x) * t }
        return LensProfile(name: "Generic Lens (\(String(format: "%.0f", focal35mm)) mm equivalent)", k1: l(a.1, b.1), k2: l(a.2, b.2),
                           vignette: [l(a.3, b.3), l(a.4, b.4), 0])
    }

    /// Smallest scale (percent) at which the corrected image covers the whole frame (Auto Scale).
    public static func autoScale(_ lc: LensCorrection, frame: PixelRect) -> Double {
        func covers(_ scale: Double) -> Bool {
            var l = lc
            l.scale = scale
            let m = LensMap(l, frame: frame)
            let (x0, y0, x1, y1) = (Double(frame.x0), Double(frame.y0), Double(frame.x1), Double(frame.y1))
            return (0...40).allSatisfy { i in
                let t = Double(i) / 40
                return [(x0 + t * (x1 - x0), y0), (x0 + t * (x1 - x0), y1), (x0, y0 + t * (y1 - y0)), (x1, y0 + t * (y1 - y0))].allSatisfy { x, y in
                    guard let s = m.sample(x, y) else { return false }
                    return s.p.x >= x0 - 0.5 && s.p.x <= x1 + 0.5 && s.p.y >= y0 - 0.5 && s.p.y <= y1 + 0.5
                }
            }
        }
        // Shrink while it still covers (never below the user's baseline when it covers).
        if covers(lc.scale) { return lc.scale }
        var lo = lc.scale, hi = lc.scale
        while !covers(hi) && hi < 400 { hi *= 1.25 }
        for _ in 0..<30 {
            let mid = (lo + hi) / 2
            if covers(mid) { hi = mid } else { lo = mid }
        }
        return hi
    }

    /// Angle (degrees, for `LensCorrection.angle`) that makes the line `a → b` horizontal or
    /// vertical, whichever it is closer to (the Straighten tool).
    public static func straightenAngle(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
        let deg = atan2(b.y - a.y, b.x - a.x) * (180 / Double.pi)
        // Nearest multiple of 90°.
        let target = (deg / 90).rounded() * 90
        return -(deg - target)
    }

    /// Applies a lens correction to `src` over `frame` (normally the canvas) — photocraft
    /// `correct`. Transparency adds an alpha channel to a surface without one. `.auto`/`.gpu` run
    /// the Metal kernels when the frame fits one pass; the call never fails (CPU fallback).
    public static func correct(_ src: Surface, frame: PixelRect, _ lc: LensCorrection, on backend: Backend = .auto) -> Surface {
        let map = LensMap(lc, frame: frame)
        let sfmt = src.format
        let needsAlpha = lc.edge == .transparency && !sfmt.alpha
        let ofmt = needsAlpha ? sfmt.with(alpha: true) : sfmt
        var out = Surface(format: ofmt)
        if frame.isEmpty { return out }
        let ctx = FilterContext(bounds: frame, format: ofmt)
        let spec = GeometryKit.RemapSpec(ctx: ctx, channels: ofmt.channels, srcAlpha: sfmt.alpha, edge: lc.edge, clip: sfmt.sample != .f32,
                                         frame: frame, tileOrigin: SIMD2(frame.x0, frame.y0), tileClip: frame)
        let filter = GeometryKit.LensFilter(map: map, spec: spec)
        let m = FilterEngine.maxGPUSize
        if backend != .cpu, AlgoGPU.isAvailable, frame.width <= m, frame.height <= m, frame.area <= 1 << 26 {
            let img = GeometryKit.read(src, frame, addAlpha: needsAlpha)
            if let r = try? FilterEngine.apply(filter, to: img, output: frame, context: ctx, on: .gpu) {
                ResampleKit.write(&out, frame, r.data)
                ResampleKit.prune(&out)
                return out
            }
        }
        let results = GeometryKit.remapTiles(spec, out: frame, map: { map.sample($0, $1) }) { GeometryKit.read(src, $0, addAlpha: needsAlpha).data }
        for (t, d) in results { ResampleKit.write(&out, t, d) }
        ResampleKit.prune(&out)
        return out
    }

    /// `correct` on a dense image (0 outside it) over `frame` (default: the image). Returns the
    /// frame, alpha appended when Transparency needs it. `storage` is the depth the result will be
    /// stored at: integer depths clip colour to 0…1 before the edge-colour blend, as photocraft does.
    public static func correct(_ img: FloatImage, frame: PixelRect? = nil, _ lc: LensCorrection, context: FilterContext? = nil,
                               storage: SampleType = .f32, on backend: Backend = .auto) throws -> FloatImage {
        let ctx0 = context ?? FilterContext.inferred(channels: img.channels, bounds: img.rect)
        let frame = frame ?? img.rect
        let needsAlpha = lc.edge == .transparency && !ctx0.alpha
        let src = needsAlpha ? GeometryKit.appendAlpha(img) : img
        var ctx = ctx0
        ctx.alpha = ctx0.alpha || needsAlpha
        ctx.bounds = frame
        if frame.isEmpty { return FloatImage(rect: .empty, channels: src.channels) }
        let spec = GeometryKit.RemapSpec(ctx: ctx, channels: src.channels, srcAlpha: ctx0.alpha, edge: lc.edge, clip: storage != .f32,
                                         frame: frame, tileOrigin: SIMD2(frame.x0, frame.y0), tileClip: frame)
        let filter = GeometryKit.LensFilter(map: LensMap(lc, frame: frame), spec: spec)
        return try FilterEngine.apply(filter, to: src, output: frame, context: ctx, on: GeometryKit.backend(backend, fits: GeometryKit.fits(src.rect, frame)))
    }

    /// Resamples `src` through an inverse map over `outArea` (photocraft `remap`). `frame` is the
    /// image the map refers to: samples clamp to it, and pixels mapping outside it take the edge
    /// mode. `map` returns where each output pixel centre samples (nil = outside); it runs
    /// concurrently on several threads. CPU only (the map is arbitrary code).
    public static func remap(_ src: Surface, frame: PixelRect, outArea: PixelRect, edge: LensEdgeMode,
                             map: (Double, Double) -> LensSample?) -> Surface {
        let sfmt = src.format
        let needsAlpha = edge == .transparency && !sfmt.alpha
        let ofmt = needsAlpha ? sfmt.with(alpha: true) : sfmt
        var out = Surface(format: ofmt)
        if outArea.isEmpty || frame.isEmpty { return out }
        let ctx = FilterContext(bounds: frame, format: ofmt)
        let spec = GeometryKit.RemapSpec(ctx: ctx, channels: ofmt.channels, srcAlpha: sfmt.alpha, edge: edge, clip: sfmt.sample != .f32,
                                         frame: frame, tileOrigin: SIMD2(outArea.x0, outArea.y0), tileClip: outArea)
        let results = GeometryKit.remapTiles(spec, out: outArea, map: map) { GeometryKit.read(src, $0, addAlpha: needsAlpha).data }
        for (t, d) in results { ResampleKit.write(&out, t, d) }
        ResampleKit.prune(&out)
        return out
    }

    /// `remap` on a dense image (0 outside it): the result covers `outArea`.
    public static func remap(_ img: FloatImage, frame: PixelRect, outArea: PixelRect, edge: LensEdgeMode, context: FilterContext? = nil,
                             storage: SampleType = .f32, map: (Double, Double) -> LensSample?) -> FloatImage {
        let ctx0 = context ?? FilterContext.inferred(channels: img.channels, bounds: img.rect)
        let needsAlpha = edge == .transparency && !ctx0.alpha
        let src = needsAlpha ? GeometryKit.appendAlpha(img) : img
        var ctx = ctx0
        ctx.alpha = ctx0.alpha || needsAlpha
        ctx.bounds = frame
        var res = FloatImage(rect: outArea, channels: src.channels)
        if outArea.isEmpty || frame.isEmpty { return res }
        let spec = GeometryKit.RemapSpec(ctx: ctx, channels: src.channels, srcAlpha: ctx0.alpha, edge: edge, clip: storage != .f32,
                                         frame: frame, tileOrigin: SIMD2(outArea.x0, outArea.y0), tileClip: outArea)
        for (t, d) in GeometryKit.remapTiles(spec, out: outArea, map: map, read: { src.crop($0).data }) { GeometryKit.paste(&res, t, d) }
        return res
    }
}
