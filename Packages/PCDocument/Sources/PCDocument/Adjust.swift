// Adjustment parameters (data only) and the curve / hue-range maths that belong to the model.
// Evaluation lives in the compositor (PCRender).
// Port of photocraft-doc (crates/doc/src/adjust.rs), MIT OR Apache-2.0, © ArtCraft Team and the
// PhotoCraft contributors.

import Foundation

/// One point of a Curves / contour / duotone curve, both coordinates in 0...1.
public struct CurvePoint: Hashable, Sendable, Codable {
    public var input: Float
    public var output: Float
    public init(input: Float, output: Float) { self.input = input; self.output = output }
}

/// Whether `points` is the straight 0→0, 1→1 line (or too short to be a curve).
public func isIdentityCurve(_ points: [CurvePoint]) -> Bool {
    if points.count == 2 {
        let (a, b) = (points[0], points[1])
        return a.input == 0 && a.output == 0 && b.input == 1 && b.output == 1
    }
    return points.count < 2
}

/// Entries in a pencil-drawn Curves map (one per 8-bit level, as in PSD `curv` maps).
public let curveMapLength = 256

/// A pencil-mode curve from its map: `outputs[k]` (0...1) is the output at input `k / 255`.
/// Missing (or non-finite) entries repeat the last one; extra entries are ignored.
public func curveMap(_ outputs: [Float]) -> [CurvePoint] {
    let last = Float(curveMapLength - 1)
    var prev: Float = 0
    return (0..<curveMapLength).map { k in
        let out: Float
        if k < outputs.count, outputs[k].isFinite { out = min(max(outputs[k], 0), 1) } else { out = prev }
        prev = out
        return CurvePoint(input: Float(k) / last, output: out)
    }
}

/// The `curveMapLength` outputs (0...1) of `points` read as a pencil-mode curve: straight segments
/// between the points, constant outside the first/last (identity without two points).
public func curveMapOutputs(_ points: [CurvePoint]) -> [Float] {
    // Stable sort by input (photocraft sorts with `total_cmp`, stable).
    let pts = points.enumerated()
        .filter { $0.element.input.isFinite && $0.element.output.isFinite }
        .sorted { $0.element.input != $1.element.input ? $0.element.input < $1.element.input : $0.offset < $1.offset }
        .map { ($0.element.input, $0.element.output) }
    let last = Float(curveMapLength - 1)
    return (0..<curveMapLength).map { k in
        let x = Float(k) / last
        var y = x
        if pts.count >= 2, let a = pts.first, let b = pts.last {
            if x <= a.0 {
                y = a.1
            } else if x >= b.0 {
                y = b.1
            } else {
                let i = pts.firstIndex { !($0.0 < x) } ?? pts.count
                if i >= 1, i < pts.count, pts[i].0 > pts[i - 1].0 {
                    let (p0, p1) = (pts[i - 1], pts[i])
                    y = p0.1 + (p1.1 - p0.1) * (x - p0.0) / (p1.0 - p0.0)
                } else if i < pts.count {
                    y = pts[i].1
                } else {
                    y = b.1
                }
            }
        }
        return min(max(y, 0), 1)
    }
}

/// Number of values in the table of a `size`³ Color Lookup (`size³ × 3`). nil for a size below 2
/// or one whose table length overflows: a stored document's size is untrusted.
public func lut3DLength(_ size: UInt32) -> Int? {
    guard size >= 2 else { return nil }
    let s = Int(size)
    let (sq, o1) = s.multipliedReportingOverflow(by: s)
    let (cube, o2) = sq.multipliedReportingOverflow(by: s)
    let (n, o3) = cube.multipliedReportingOverflow(by: 3)
    return o1 || o2 || o3 ? nil : n
}

/// One Levels record (input black/white points, gamma, output range), all on 0...1.
public struct LevelsChannel: Hashable, Sendable, Codable {
    public var inBlack: Float = 0
    public var inWhite: Float = 1
    public var gamma: Float = 1
    public var outBlack: Float = 0
    public var outWhite: Float = 1

    public init(inBlack: Float = 0, inWhite: Float = 1, gamma: Float = 1, outBlack: Float = 0, outWhite: Float = 1) {
        self.inBlack = inBlack; self.inWhite = inWhite; self.gamma = gamma; self.outBlack = outBlack; self.outWhite = outWhite
    }

    public var isIdentity: Bool { self == LevelsChannel() }

    enum CodingKeys: String, CodingKey {
        case inBlack = "in_black", inWhite = "in_white", gamma, outBlack = "out_black", outWhite = "out_white"
    }
}

/// Which document channels the per-channel records of Levels and Curves address. Compositing
/// happens in display RGB; `cmyk` and `lab` records are applied to the pixel converted into that
/// space (the same conversions the document's surfaces use), so ink and Lab channel edits behave
/// like Photoshop's in CMYK and Lab documents. Grayscale documents use `rgb` with the master record.
public enum ToneSpace: String, Hashable, Sendable, Codable, CaseIterable {
    /// `perChannel` = red, green, blue.
    case rgb = "Rgb"
    /// `perChannel` = cyan, magenta, yellow plus `black`; values are channel brightness
    /// (1 − ink), and the master record applies to all four inks.
    case cmyk = "Cmyk"
    /// `perChannel` = lightness, a, b (stored 0...1 like Lab surfaces); there is no composite
    /// record in Lab, so the master is ignored.
    case lab = "Lab"
}

/// Rust's `f32::rem_euclid`: the remainder of `x / m` in `[0, |m|)` (hue wrap-around).
@inlinable public func remEuclid(_ x: Float, _ m: Float) -> Float {
    let r = x.truncatingRemainder(dividingBy: m)
    return r < 0 ? r + abs(m) : r
}

/// One of Hue/Saturation's six colour ranges (reds, yellows, greens, cyans, blues, magentas).
public struct HueRange: Hashable, Sendable, Codable {
    /// Hue shift in degrees (-180...180).
    public var hue: Float
    /// Saturation change in percent (-100...100).
    public var saturation: Float
    /// Lightness change in percent (-100...100).
    public var lightness: Float
    /// Hue degrees where the range starts fading in, is fully on, starts fading out and ends
    /// (Photoshop's four range sliders). May wrap past 0/360.
    public var bounds: SIMD4<Float>

    public init(hue: Float = 0, saturation: Float = 0, lightness: Float = 0, bounds: SIMD4<Float>) {
        self.hue = hue; self.saturation = saturation; self.lightness = lightness; self.bounds = bounds
    }

    /// The neutral range `i` (0 = reds … 5 = magentas) with Photoshop's default extent: fully on
    /// for 30° around its centre, fading over 30° each side.
    public static func neutral(_ i: Int) -> HueRange {
        let c = 60 * Float(i)
        return HueRange(bounds: SIMD4(c - 45, c - 15, c + 15, c + 45))
    }

    /// The six neutral ranges.
    public static var defaults: [HueRange] { (0..<6).map(neutral) }

    /// The canonical form of four range sliders: increasing, within one turn, centre in -30..<330
    /// (so the default reds are -45, -15, 15, 45 whichever way they were written).
    public static func canonicalBounds(_ b: SIMD4<Float>) -> SIMD4<Float> {
        if !(b.x.isFinite && b.y.isFinite && b.z.isFinite && b.w.isFinite) { return SIMD4(-45, -15, 15, 45) }
        var out = SIMD4<Float>(repeating: b[0])
        for k in 1..<4 {
            out[k] = Float.minimum(out[k - 1] + remEuclid(b[k] - out[k - 1], 360), out[0] + 359)
        }
        let centre = (out[1] + out[2]) / 2
        let shift = remEuclid(centre + 30, 360) - 30 - centre
        return out + shift
    }

    public var isNeutral: Bool { hue == 0 && saturation == 0 && lightness == 0 }

    /// How much a pixel of hue `deg` (degrees) belongs to this range, 0...1.
    public func weight(_ deg: Float) -> Float {
        let a = bounds.x
        // Measure from the range's start so wrap-around ranges (reds) work.
        func rel(_ x: Float) -> Float { x.isFinite ? remEuclid(x - a, 360) : 0 }
        let b = rel(bounds.y)
        let c = Float.maximum(rel(bounds.z), b)
        let d = Float.maximum(rel(bounds.w), c)
        let h = rel(deg)
        if h <= b { return b <= 0 ? 1 : h / b }
        if h <= c { return 1 }
        if h <= d { return d <= c ? 1 : (d - h) / (d - c) }
        return 0
    }
}

/// One Gradient Map stop: location 0...1 and an sRGB colour. JSON: `[location, [r, g, b]]`.
public struct GradientMapStop: Hashable, Sendable, Codable {
    public var location: Float
    public var rgb: SIMD3<Float>

    public init(_ location: Float, _ rgb: SIMD3<Float>) { self.location = location; self.rgb = rgb }

    public init(from decoder: any Decoder) throws {
        var c = try decoder.unkeyedContainer()
        location = try c.decode(Float.self)
        rgb = try c.decode(SIMD3<Float>.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(location)
        try c.encode(rgb)
    }
}

/// Photoshop adjustment layers (Layer › New Adjustment Layer). JSON: serde's externally tagged
/// form (`{"Levels":{…}}`, `"Invert"`).
public enum Adjustment: Hashable, Sendable, Codable {
    case brightnessContrast(BrightnessContrast)
    /// R, G, B (or the channels `space` names) first, then the master (composite) record. In CMYK
    /// this also applies to `black`; in Lab the master is ignored.
    case levels(Levels)
    /// R, G, B curves (or the channels `space` names) first, then the master (composite) curve. In
    /// CMYK this also applies to `black`; in Lab the master is ignored.
    case curves(Curves)
    case exposure(Exposure)
    case vibrance(Vibrance)
    /// Master hue / saturation / lightness (or the Colorize colour) plus six hue ranges.
    case hueSaturation(HueSaturation)
    case colorBalance(ColorBalance)
    case blackWhite(BlackWhite)
    case photoFilter(PhotoFilter)
    case channelMixer(ChannelMixer)
    /// A 3D LUT (see `ColorLookup`).
    case colorLookup(ColorLookup)
    case invert
    case posterize(levels: UInt32)
    case threshold(level: Float)
    case gradientMap(GradientMap)
    /// Per range (reds, yellows, greens, cyans, blues, magentas, whites, neutrals, blacks) the
    /// cyan, magenta, yellow and black change in percent (-100...100), as in Photoshop.
    case selectiveColor(SelectiveColor)
    /// A PSD adjustment we can't evaluate yet; preserved raw for round-trip.
    case unsupported(psdKey: String, raw: [UInt8])

    public struct BrightnessContrast: Hashable, Sendable, Codable {
        /// Photoshop 27's Brightness/Contrast algorithms (the PSD descriptor's `brightnessMode`).
        public enum Mode: String, Hashable, Sendable, Codable, CaseIterable {
            /// "Use Legacy": brightness added, contrast scaled about 128.
            case legacy
            /// CS3's Brightness/Contrast (`brightnessModeModern`): one curve per channel.
            case modern
            /// Photoshop 27's default in RGB 8/16-bit documents (`brightnessModeLight`): Exposure,
            /// Contrast, Highlights, Shadows, Whites and Blacks; it ignores `brightness`.
            case light
        }

        /// Photoshop 27's ranges (M3 `lightModeDescriptor`; out-of-range values are clamped
        /// silently, as Photoshop does): Exposure −5…5 (a double), Whites / Blacks / Highlights /
        /// Shadows −100…100, Light's Contrast −100…100 (Modern's −50…100).
        public static let exposureRange: ClosedRange<Float> = -5...5
        public static let toneRange: ClosedRange<Float> = -100...100
        public static let lightContrastRange: ClosedRange<Float> = -100...100

        public var brightness: Float
        /// Clamped to `lightContrastRange` in Light mode.
        public var contrast: Float { didSet { clampLight() } }
        public var mode: Mode { didSet { clampLight() } }
        /// Light mode's Exposure (`brightnessExposure`, `exposureRange`); ignored by the other modes.
        public var exposure: Float { didSet { clampLight() } }
        /// Light mode's Whites, Blacks, Highlights and Shadows (`toneRange`); ignored by the others.
        public var whites: Float { didSet { clampLight() } }
        public var blacks: Float { didSet { clampLight() } }
        public var highlights: Float { didSet { clampLight() } }
        public var shadows: Float { didSet { clampLight() } }

        private static func clamp(_ v: Float, _ r: ClosedRange<Float>) -> Float { v.isNaN ? 0 : min(max(v, r.lowerBound), r.upperBound) }
        /// Photoshop's silent clamps on Light's controls (and on Contrast while in Light mode).
        private mutating func clampLight() {
            func set(_ k: WritableKeyPath<Self, Float>, _ r: ClosedRange<Float>) {
                let v = Self.clamp(self[keyPath: k], r)
                if v != self[keyPath: k] { self[keyPath: k] = v }
            }
            set(\.exposure, Self.exposureRange)
            for k in [\Self.whites, \Self.blacks, \Self.highlights, \Self.shadows] { set(k, Self.toneRange) }
            if mode == .light { set(\.contrast, Self.lightContrastRange) }
        }

        /// Whether the mode is `.legacy` (setting it false makes a legacy adjustment modern).
        public var legacy: Bool {
            get { mode == .legacy }
            set { if newValue { mode = .legacy } else if mode == .legacy { mode = .modern } }
        }

        public init(brightness: Float = 0, contrast: Float = 0, legacy: Bool = false) {
            self.init(brightness: brightness, contrast: contrast, mode: legacy ? .legacy : .modern)
        }

        public init(brightness: Float = 0, contrast: Float = 0, mode: Mode, exposure: Float = 0, whites: Float = 0, blacks: Float = 0,
                    highlights: Float = 0, shadows: Float = 0) {
            self.brightness = brightness; self.contrast = contrast; self.mode = mode
            self.exposure = exposure; self.whites = whites; self.blacks = blacks; self.highlights = highlights; self.shadows = shadows
            clampLight()
        }

        enum CodingKeys: String, CodingKey { case brightness, contrast, legacy, mode, exposure, whites, blacks, highlights, shadows }

        /// JSON: `{"brightness", "contrast", "legacy"}` as before; `mode` and Light's controls are
        /// added only for Light mode, so legacy / modern adjustments serialise unchanged.
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            brightness = try c.decode(.brightness, or: 0)
            contrast = try c.decode(.contrast, or: 0)
            let legacy: Bool = try c.decode(.legacy, or: false)
            mode = try c.decode(.mode, or: legacy ? .legacy : .modern)
            exposure = try c.decode(.exposure, or: 0)
            whites = try c.decode(.whites, or: 0)
            blacks = try c.decode(.blacks, or: 0)
            highlights = try c.decode(.highlights, or: 0)
            shadows = try c.decode(.shadows, or: 0)
            clampLight()
        }

        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(brightness, forKey: .brightness)
            try c.encode(contrast, forKey: .contrast)
            try c.encode(legacy, forKey: .legacy)
            if mode == .light {
                try c.encode(mode, forKey: .mode)
                try c.encode(exposure, forKey: .exposure)
                try c.encode(whites, forKey: .whites)
                try c.encode(blacks, forKey: .blacks)
                try c.encode(highlights, forKey: .highlights)
                try c.encode(shadows, forKey: .shadows)
            }
        }
    }

    public struct Levels: Hashable, Sendable, Codable {
        public var master: LevelsChannel
        /// Exactly three records.
        public var perChannel: [LevelsChannel]
        public var space: ToneSpace
        /// The black ink channel when `space` is `.cmyk`.
        public var black: LevelsChannel

        public init(master: LevelsChannel = .init(), perChannel: [LevelsChannel] = Array(repeating: .init(), count: 3),
                    space: ToneSpace = .rgb, black: LevelsChannel = .init()) {
            self.master = master; self.perChannel = perChannel; self.space = space; self.black = black
        }

        enum CodingKeys: String, CodingKey { case master, perChannel = "per_channel", space, black }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            master = try c.decode(LevelsChannel.self, forKey: .master)
            perChannel = try c.decodeFixed([LevelsChannel].self, forKey: .perChannel, count: 3)
            space = try c.decode(.space, or: .rgb)
            black = try c.decode(.black, or: LevelsChannel())
        }
    }

    public struct Curves: Hashable, Sendable, Codable {
        public var master: [CurvePoint]
        /// Exactly three curves.
        public var perChannel: [[CurvePoint]]
        public var space: ToneSpace
        /// The black ink curve when `space` is `.cmyk` (empty = identity).
        public var black: [CurvePoint]
        /// Drawn with the pencil (Photoshop's "Draw to modify the curve", PSD `curv` map form):
        /// every curve is a `curveMapLength`-entry map (see `curveMap`) evaluated piecewise-linearly
        /// instead of a spline through its points.
        public var pencil: Bool

        public init(master: [CurvePoint], perChannel: [[CurvePoint]], space: ToneSpace = .rgb, black: [CurvePoint] = [], pencil: Bool = false) {
            self.master = master; self.perChannel = perChannel; self.space = space; self.black = black; self.pencil = pencil
        }

        enum CodingKeys: String, CodingKey { case master, perChannel = "per_channel", space, black, pencil }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            master = try c.decode([CurvePoint].self, forKey: .master)
            perChannel = try c.decodeFixed([[CurvePoint]].self, forKey: .perChannel, count: 3)
            space = try c.decode(.space, or: .rgb)
            black = try c.decode(.black, or: [])
            pencil = try c.decode(.pencil, or: false)
        }
    }

    public struct Exposure: Hashable, Sendable, Codable {
        public var exposure: Float
        public var offset: Float
        public var gamma: Float
        public init(exposure: Float = 0, offset: Float = 0, gamma: Float = 1) {
            self.exposure = exposure; self.offset = offset; self.gamma = gamma
        }
    }

    public struct Vibrance: Hashable, Sendable, Codable {
        public var vibrance: Float
        public var saturation: Float
        public init(vibrance: Float = 0, saturation: Float = 0) { self.vibrance = vibrance; self.saturation = saturation }
    }

    public struct HueSaturation: Hashable, Sendable, Codable {
        public var hue: Float
        public var saturation: Float
        public var lightness: Float
        public var colorize: Bool
        /// Exactly six ranges: reds, yellows, greens, cyans, blues, magentas.
        public var ranges: [HueRange]

        public init(hue: Float = 0, saturation: Float = 0, lightness: Float = 0, colorize: Bool = false, ranges: [HueRange] = HueRange.defaults) {
            self.hue = hue; self.saturation = saturation; self.lightness = lightness; self.colorize = colorize; self.ranges = ranges
        }

        enum CodingKeys: String, CodingKey { case hue, saturation, lightness, colorize, ranges }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            hue = try c.decode(Float.self, forKey: .hue)
            saturation = try c.decode(Float.self, forKey: .saturation)
            lightness = try c.decode(Float.self, forKey: .lightness)
            colorize = try c.decode(Bool.self, forKey: .colorize)
            ranges = c.contains(.ranges) ? try c.decodeFixed([HueRange].self, forKey: .ranges, count: 6) : HueRange.defaults
        }
    }

    public struct ColorBalance: Hashable, Sendable, Codable {
        public var shadows: SIMD3<Float>
        public var midtones: SIMD3<Float>
        public var highlights: SIMD3<Float>
        public var preserveLuminosity: Bool

        public init(shadows: SIMD3<Float> = .zero, midtones: SIMD3<Float> = .zero, highlights: SIMD3<Float> = .zero, preserveLuminosity: Bool = true) {
            self.shadows = shadows; self.midtones = midtones; self.highlights = highlights; self.preserveLuminosity = preserveLuminosity
        }

        enum CodingKeys: String, CodingKey { case shadows, midtones, highlights, preserveLuminosity = "preserve_luminosity" }
    }

    public struct BlackWhite: Hashable, Sendable, Codable {
        /// Exactly six weights: reds, yellows, greens, cyans, blues, magentas.
        public var weights: [Float]
        public var tint: SIMD3<Float>?

        public init(weights: [Float], tint: SIMD3<Float>? = nil) { self.weights = weights; self.tint = tint }

        enum CodingKeys: String, CodingKey { case weights, tint }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            weights = try c.decodeFixed([Float].self, forKey: .weights, count: 6)
            tint = try c.decodeIfPresent(SIMD3<Float>.self, forKey: .tint)
        }
    }

    public struct PhotoFilter: Hashable, Sendable, Codable {
        public var color: SIMD3<Float>
        public var density: Float
        public var preserveLuminosity: Bool

        public init(color: SIMD3<Float>, density: Float, preserveLuminosity: Bool = true) {
            self.color = color; self.density = density; self.preserveLuminosity = preserveLuminosity
        }

        enum CodingKeys: String, CodingKey { case color, density, preserveLuminosity = "preserve_luminosity" }
    }

    public struct ChannelMixer: Hashable, Sendable, Codable {
        /// Output R, G, B rows: (red, green, blue, constant).
        public var matrix: [SIMD4<Float>]
        public var monochrome: Bool

        public init(matrix: [SIMD4<Float>], monochrome: Bool = false) { self.matrix = matrix; self.monochrome = monochrome }

        enum CodingKeys: String, CodingKey { case matrix, monochrome }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            matrix = try c.decodeFixed([SIMD4<Float>].self, forKey: .matrix, count: 3)
            monochrome = try c.decode(Bool.self, forKey: .monochrome)
        }
    }

    /// A 3D LUT: `size`³ RGB triplets, red varying fastest (`((b·size + g)·size + r)·3`), in 0...1.
    /// `lut` is nil for a lookup Photoshop stores as an ICC profile (identity here).
    public struct ColorLookup: Hashable, Sendable, Codable {
        public var name: String
        public var lut: [Float]?
        public var size: UInt32
        /// Tetrahedral instead of trilinear interpolation.
        public var tetrahedral: Bool
        /// Ordered dither of ±½ an 8-bit step to hide banding (Photoshop's "Dither").
        public var dither: Bool

        public init(name: String, lut: [Float]?, size: UInt32, tetrahedral: Bool = false, dither: Bool = false) {
            self.name = name; self.lut = lut; self.size = size; self.tetrahedral = tetrahedral; self.dither = dither
        }

        enum CodingKeys: String, CodingKey { case name, lut, size, tetrahedral, dither }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            lut = try c.decodeIfPresent([Float].self, forKey: .lut)
            size = try c.decode(UInt32.self, forKey: .size)
            tetrahedral = try c.decode(.tetrahedral, or: false)
            dither = try c.decode(.dither, or: false)
        }
    }

    public struct GradientMap: Hashable, Sendable, Codable {
        public var stops: [GradientMapStop]
        public var reverse: Bool
        /// Ordered dither of ±½ an 8-bit step to hide banding.
        public var dither: Bool

        public init(stops: [GradientMapStop], reverse: Bool = false, dither: Bool = false) {
            self.stops = stops; self.reverse = reverse; self.dither = dither
        }

        enum CodingKeys: String, CodingKey { case stops, reverse, dither }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            stops = try c.decode([GradientMapStop].self, forKey: .stops)
            reverse = try c.decode(Bool.self, forKey: .reverse)
            dither = try c.decode(.dither, or: false)
        }
    }

    public struct SelectiveColor: Hashable, Sendable, Codable {
        public var relative: Bool
        /// Exactly nine (cyan, magenta, yellow, black) records.
        public var adjustments: [SIMD4<Float>]

        public init(relative: Bool = true, adjustments: [SIMD4<Float>] = Array(repeating: .zero, count: 9)) {
            self.relative = relative; self.adjustments = adjustments
        }

        enum CodingKeys: String, CodingKey { case relative, adjustments }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            relative = try c.decode(Bool.self, forKey: .relative)
            adjustments = try c.decodeFixed([SIMD4<Float>].self, forKey: .adjustments, count: 9)
        }
    }

    public var label: String {
        switch self {
        case .brightnessContrast: "Brightness/Contrast"
        case .levels: "Levels"
        case .curves: "Curves"
        case .exposure: "Exposure"
        case .vibrance: "Vibrance"
        case .hueSaturation: "Hue/Saturation"
        case .colorBalance: "Color Balance"
        case .blackWhite: "Black & White"
        case .photoFilter: "Photo Filter"
        case .channelMixer: "Channel Mixer"
        case .colorLookup: "Color Lookup"
        case .invert: "Invert"
        case .posterize: "Posterize"
        case .threshold: "Threshold"
        case .gradientMap: "Gradient Map"
        case .selectiveColor: "Selective Color"
        case .unsupported: "Adjustment"
        }
    }

    public static func defaultHueSaturation() -> Adjustment { .hueSaturation(HueSaturation()) }

    public static func identityCurves() -> Adjustment {
        let line = [CurvePoint(input: 0, output: 0), CurvePoint(input: 1, output: 1)]
        return .curves(Curves(master: line, perChannel: [line, line, line]))
    }

    public static func identityLevels() -> Adjustment { .levels(Levels()) }

    // MARK: Codable (serde externally tagged)

    private struct PosterizePayload: Codable { var levels: UInt32 }
    private struct ThresholdPayload: Codable { var level: Float }
    private struct UnsupportedPayload: Codable {
        var psdKey: String
        var raw: [UInt8]
        enum CodingKeys: String, CodingKey { case psdKey = "psd_key", raw }
    }

    public init(from decoder: any Decoder) throws {
        let v = try TaggedVariant(from: decoder)
        switch v.tag {
        case "BrightnessContrast": self = .brightnessContrast(try v.payload())
        case "Levels": self = .levels(try v.payload())
        case "Curves": self = .curves(try v.payload())
        case "Exposure": self = .exposure(try v.payload())
        case "Vibrance": self = .vibrance(try v.payload())
        case "HueSaturation": self = .hueSaturation(try v.payload())
        case "ColorBalance": self = .colorBalance(try v.payload())
        case "BlackWhite": self = .blackWhite(try v.payload())
        case "PhotoFilter": self = .photoFilter(try v.payload())
        case "ChannelMixer": self = .channelMixer(try v.payload())
        case "ColorLookup": self = .colorLookup(try v.payload())
        case "Invert": self = .invert
        case "Posterize": self = .posterize(levels: try v.payload(PosterizePayload.self).levels)
        case "Threshold": self = .threshold(level: try v.payload(ThresholdPayload.self).level)
        case "GradientMap": self = .gradientMap(try v.payload())
        case "SelectiveColor": self = .selectiveColor(try v.payload())
        case "Unsupported":
            let p = try v.payload(UnsupportedPayload.self)
            self = .unsupported(psdKey: p.psdKey, raw: p.raw)
        default: throw v.unknown()
        }
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .brightnessContrast(let p): try Tagged.variant("BrightnessContrast", p, to: encoder)
        case .levels(let p): try Tagged.variant("Levels", p, to: encoder)
        case .curves(let p): try Tagged.variant("Curves", p, to: encoder)
        case .exposure(let p): try Tagged.variant("Exposure", p, to: encoder)
        case .vibrance(let p): try Tagged.variant("Vibrance", p, to: encoder)
        case .hueSaturation(let p): try Tagged.variant("HueSaturation", p, to: encoder)
        case .colorBalance(let p): try Tagged.variant("ColorBalance", p, to: encoder)
        case .blackWhite(let p): try Tagged.variant("BlackWhite", p, to: encoder)
        case .photoFilter(let p): try Tagged.variant("PhotoFilter", p, to: encoder)
        case .channelMixer(let p): try Tagged.variant("ChannelMixer", p, to: encoder)
        case .colorLookup(let p): try Tagged.variant("ColorLookup", p, to: encoder)
        case .invert: try Tagged.unit("Invert", to: encoder)
        case .posterize(let levels): try Tagged.variant("Posterize", PosterizePayload(levels: levels), to: encoder)
        case .threshold(let level): try Tagged.variant("Threshold", ThresholdPayload(level: level), to: encoder)
        case .gradientMap(let p): try Tagged.variant("GradientMap", p, to: encoder)
        case .selectiveColor(let p): try Tagged.variant("SelectiveColor", p, to: encoder)
        case .unsupported(let key, let raw): try Tagged.variant("Unsupported", UnsupportedPayload(psdKey: key, raw: raw), to: encoder)
        }
    }
}
