// Colour-mode side data: the Indexed Color table, Duotone inks, and smart-object stack modes.
// Port of photocraft-doc (crates/doc/src/mode.rs), MIT OR Apache-2.0, © ArtCraft Team and the
// PhotoCraft contributors.
//
// Indexed, Bitmap and Duotone documents keep their pixels expanded (RGB / Gray, see
// `Document.pixelFormat`); these structs carry what the mode adds on top.

/// Image › Mode › Color Table: the palette of an Indexed Color document (at most 256 entries).
public struct ColorTable: Hashable, Sendable, Codable {
    /// sRGB 8-bit entries.
    public var colors: [SIMD3<UInt8>]
    /// Index of the entry shown as transparent (Indexed Color › Transparency).
    public var transparent: UInt8?

    public init(colors: [SIMD3<UInt8>] = [], transparent: UInt8? = nil) { self.colors = colors; self.transparent = transparent }

    /// Nearest palette index for an RGB colour in 0...1 (squared distance, ties to the lower index).
    public func nearest(_ c: SIMD3<Float>) -> Int {
        var best: (Float, Int) = (.greatestFiniteMagnitude, 0)
        for (i, e) in colors.enumerated() {
            var d: Float = 0
            for k in 0..<3 {
                let x = c[k] - Float(e[k]) / 255
                d += x * x
            }
            if d < best.0 { best = (d, i) }
        }
        return best.1
    }

    /// Entry `i` as RGB in 0...1 (black past the end).
    public func rgb(_ i: Int) -> SIMD3<Float> {
        guard i >= 0, i < colors.count else { return .zero }
        let e = colors[i]
        return SIMD3(Float(e.x) / 255, Float(e.y) / 255, Float(e.z) / 255)
    }
}

/// One Duotone ink: its display colour and the curve mapping gray density to ink density.
public struct DuotoneInk: Hashable, Sendable, Codable {
    public var name: String
    /// Display colour of the solid ink (sRGB 0...1).
    public var color: SIMD3<Float>
    /// Ink density curve, input = gray *density* (0 = paper, 1 = solid), output = ink density.
    public var curve: [CurvePoint]

    public init(name: String, color: SIMD3<Float>, curve: [CurvePoint]? = nil) {
        self.name = name
        self.color = color
        self.curve = curve ?? [CurvePoint(input: 0, output: 0), CurvePoint(input: 1, output: 1)]
    }

    /// Ink density for a gray density (0 = paper, 1 = solid) through the ink's curve.
    public func density(_ grayDensity: Float) -> Float {
        min(max(curveEval(curve, min(max(grayDensity, 0), 1)), 0), 1)
    }
}

/// Image › Mode › Duotone: 1–4 inks (Monotone, Duotone, Tritone, Quadtone) printed over paper.
public struct Duotone: Hashable, Sendable, Codable {
    public var inks: [DuotoneInk]
    /// The PSD colour-mode data this came from, written back unchanged while the inks are unedited.
    public var psdRaw: [UInt8]?

    public init(inks: [DuotoneInk], psdRaw: [UInt8]? = nil) { self.inks = inks; self.psdRaw = psdRaw }

    enum CodingKeys: String, CodingKey { case inks, psdRaw = "psd_raw" }

    /// Simulated print colour of a gray value (0 = black, 1 = white): inks multiply over white paper.
    public func render(_ gray: Float) -> SIMD3<Float> {
        let density = 1 - min(max(gray, 0), 1)
        var out = SIMD3<Float>(repeating: 1)
        for ink in inks {
            let d = curveEval(ink.curve, density)
            // Each ink filters light: full density transmits the ink colour.
            for k in 0..<3 { out[k] *= 1 - d * (1 - ink.color[k]) }
        }
        return out
    }

    /// A Gradient Map that turns the gray composite into the printed look; displays and flat
    /// exports put it on top of a copy of the document.
    public var displayAdjustment: Adjustment {
        let stops = (0...32).map { i -> GradientMapStop in
            let t = Float(i) / 32
            return GradientMapStop(t, render(t))
        }
        return .gradientMap(.init(stops: stops, reverse: false, dither: false))
    }
}

/// Piecewise-linear evaluation (Photoshop's duotone curves are 13-point linear transfer curves).
func curveEval(_ pts: [CurvePoint], _ x: Float) -> Float {
    switch pts.count {
    case 0: return x
    case 1: return pts[0].output
    default:
        if x <= pts[0].input { return pts[0].output }
        for k in 0..<(pts.count - 1) {
            let (w0, w1) = (pts[k], pts[k + 1])
            if x <= w1.input {
                let span = Float.maximum(w1.input - w0.input, 1e-6)
                return w0.output + (w1.output - w0.output) * (x - w0.input) / span
            }
        }
        return pts[pts.count - 1].output
    }
}

/// Layer › Smart Objects › Stack Mode: a per-pixel statistic over the smart object's layers.
/// JSON: the PascalCase name (`"StandardDeviation"`).
public enum StackMode: String, CaseIterable, Hashable, Sendable, Codable {
    case entropy = "Entropy"
    case kurtosis = "Kurtosis"
    case maximum = "Maximum"
    case mean = "Mean"
    case median = "Median"
    case minimum = "Minimum"
    case range = "Range"
    case skewness = "Skewness"
    case standardDeviation = "StandardDeviation"
    case summation = "Summation"
    case variance = "Variance"

    public static var all: [StackMode] { allCases }

    /// The menu-id suffix (`layer.smartObjects.stackMode.<id>`).
    public var id: String {
        switch self {
        case .entropy: "entropy"
        case .kurtosis: "kurtosis"
        case .maximum: "maximum"
        case .mean: "mean"
        case .median: "median"
        case .minimum: "minimum"
        case .range: "range"
        case .skewness: "skewness"
        case .standardDeviation: "standardDeviation"
        case .summation: "summation"
        case .variance: "variance"
        }
    }

    public init?(id: String) {
        guard let m = StackMode.allCases.first(where: { $0.id == id }) else { return nil }
        self = m
    }

    public var label: String {
        switch self {
        case .standardDeviation: "Standard Deviation"
        default: rawValue
        }
    }
}
