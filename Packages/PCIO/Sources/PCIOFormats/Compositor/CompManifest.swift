// Compositor's `.comp` project manifest (format `com.compositor.project`, versions 1–13): the
// records and the version gates `ProjectStore.validate` applies, read leniently (a missing
// optional setting takes Compositor's default) but gated exactly (a field a version can't hold
// is refused, as Compositor refuses it).
// Mirrors Compositor's IO/ProjectStore.swift (ProjectManifest, ProjectLayerRecord, validate) and
// the Document/ value types it encodes (LayerTransform, LayerAdjustment and its settings,
// LayerEffects, LayerShapeStyle, LayerTextStyle, CanvasGuide), described in docs/project-format.md.
// Compositor is MIT, © 2026 Wonder Assembly LLC; this is a reader written from that format, not
// a copy of its code.

import Foundation

/// The decoded `manifest.json` of a `.comp` package.
public struct CompManifest: Decodable, Sendable {
    /// The format identifier every manifest carries.
    public static let formatID = "com.compositor.project"
    /// The versions Compositor's `ProjectStore` reads (`ProjectManifest.supported`).
    public static let supported = 1 ... 13

    public var format: String
    public var version: Int
    public var colorSpace: String
    /// Pixels per inch; missing in older version-1 files (72).
    public var resolution: Double?
    public var documentID: UUID
    public var width: Int
    public var height: Int
    public var activeLayerID: UUID?
    /// Bottom to top; a group's children follow it wherever they sit, ordered among themselves.
    public var layers: [CompLayer]
    /// Missing on versions 1–7.
    public var guides: [CompGuide]?

    enum CodingKeys: String, CodingKey {
        case format, version, colorSpace, resolution, documentID, width, height, activeLayerID, layers, guides
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try c.decode(String.self, forKey: .format)
        version = try c.decode(Int.self, forKey: .version)
        colorSpace = try c.decodeIfPresent(String.self, forKey: .colorSpace) ?? "sRGB"
        resolution = try c.decodeIfPresent(Double.self, forKey: .resolution)
        documentID = try c.decode(UUID.self, forKey: .documentID)
        width = try c.decode(Int.self, forKey: .width)
        height = try c.decode(Int.self, forKey: .height)
        activeLayerID = try c.decodeIfPresent(UUID.self, forKey: .activeLayerID)
        layers = try c.decode([CompLayer].self, forKey: .layers)
        guides = try c.decodeIfPresent([CompGuide].self, forKey: .guides)
    }
}

/// One `ProjectLayerRecord`.
public struct CompLayer: Decodable, Sendable {
    public var id: UUID
    public var name: String
    public var isVisible: Bool
    public var transform: CompTransform
    /// `<id>.png` (8- or, from v12, 16-bit) or, from v13, `<id>.exr`; nil for blank, group and
    /// adjustment layers.
    public var imageFile: String?
    public var parentID: UUID?
    public var isGroup: Bool?
    public var opacity: Double?
    /// Compositor's blend-mode name, kept as text so an unknown one is reported, not fatal.
    public var blendMode: String?
    public var maskFile: String?
    public var maskEnabled: Bool?
    /// The layer whose coverage this one is clipped by (v5, Compositor's clipping masks).
    public var maskSourceID: UUID?
    public var adjustment: CompAdjustment?
    /// An unlinked mask's own placement on the document.
    public var maskPlacement: CompTransform?
    /// Nil is linked.
    public var maskLinked: Bool?
    public var shape: CompShapeStyle?
    public var effects: CompEffects?
    public var text: CompTextStyle?

    public var group: Bool { isGroup == true }
}

/// A two-number value: Codable `CGPoint` / `CGSize` encode as `[x, y]`; `{x, y}` and
/// `{width, height}` objects are accepted too.
public struct CompPair: Decodable, Sendable, Equatable {
    public var a: Double
    public var b: Double
    public init(_ a: Double, _ b: Double) { self.a = a; self.b = b }

    private enum Keys: String, CodingKey { case x, y, width, height }

    public init(from decoder: any Decoder) throws {
        if var u = try? decoder.unkeyedContainer() {
            a = try u.decode(Double.self)
            b = try u.decode(Double.self)
            return
        }
        let c = try decoder.container(keyedBy: Keys.self)
        a = try c.decodeIfPresent(Double.self, forKey: .x) ?? c.decode(Double.self, forKey: .width)
        b = try c.decodeIfPresent(Double.self, forKey: .y) ?? c.decode(Double.self, forKey: .height)
    }
}

/// `LayerTransform`: the unrotated box in document pixels, turned clockwise about its centre,
/// flipped inside it, and how its pixels are resampled.
public struct CompTransform: Decodable, Sendable, Equatable {
    public enum Sampling: String, Decodable, Sendable { case nearest = "Nearest", smooth = "Smooth", high = "High quality" }

    public var originX: Double, originY: Double
    public var width: Double, height: Double
    /// Degrees, clockwise.
    public var rotation: Double
    public var flipX: Bool, flipY: Bool
    public var sampling: Sampling

    public init(originX: Double, originY: Double, width: Double, height: Double, rotation: Double = 0, flipX: Bool = false,
                flipY: Bool = false, sampling: Sampling = .high) {
        self.originX = originX; self.originY = originY; self.width = width; self.height = height
        self.rotation = rotation; self.flipX = flipX; self.flipY = flipY; self.sampling = sampling
    }

    enum CodingKeys: String, CodingKey { case origin, size, rotation, flipX, flipY, sampling }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let o = try c.decode(CompPair.self, forKey: .origin), s = try c.decode(CompPair.self, forKey: .size)
        originX = o.a; originY = o.b; width = s.a; height = s.b
        rotation = try c.decodeIfPresent(Double.self, forKey: .rotation) ?? 0
        flipX = try c.decodeIfPresent(Bool.self, forKey: .flipX) ?? false
        flipY = try c.decodeIfPresent(Bool.self, forKey: .flipY) ?? false
        // An unknown sampling name reads as the default rather than refusing the file.
        sampling = (try? c.decodeIfPresent(Sampling.self, forKey: .sampling)) ?? .high
    }

    /// `LayerTransform.isValid`.
    public var isValid: Bool {
        [originX, originY, width, height, rotation].allSatisfy(\.isFinite)
            && (1 ... 300_000).contains(width) && (1 ... 300_000).contains(height)
            && abs(originX) <= 1_000_000 && abs(originY) <= 1_000_000
    }

    /// Radians, clockwise in the document's y-down space (`rotation` modulo 360).
    public var radians: Double { rotation.truncatingRemainder(dividingBy: 360) * .pi / 180 }

    /// `BrushRaster.pixelToDocument`: a `pixelWidth` × `pixelHeight` grid (y down) onto the
    /// document, as (a, b, c, d, tx, ty) with x' = a·x + c·y + tx, y' = b·x + d·y + ty.
    public func pixelToDocument(_ pixelWidth: Int, _ pixelHeight: Int) -> (a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double) {
        let sx = width / Double(max(1, pixelWidth)) * (flipX ? -1 : 1)
        let sy = height / Double(max(1, pixelHeight)) * (flipY ? -1 : 1)
        let cs = cos(radians), sn = sin(radians)
        let a = cs * sx, b = sn * sx, c = -sn * sy, d = cs * sy
        let cx = originX + width / 2, cy = originY + height / 2
        let hx = Double(pixelWidth) / 2, hy = Double(pixelHeight) / 2
        return (a, b, c, d, cx - a * hx - c * hy, cy - b * hx - d * hy)
    }

    /// Whether `pixelWidth` × `pixelHeight` pixels land one-to-one on whole document pixels, upright
    /// and unflipped (a straight copy, no resampling).
    public func isPixelAligned(_ pixelWidth: Int, _ pixelHeight: Int) -> Bool {
        rotation.truncatingRemainder(dividingBy: 360) == 0 && !flipX && !flipY
            && width == Double(pixelWidth) && height == Double(pixelHeight)
            && originX.rounded() == originX && originY.rounded() == originY
    }

    /// The same placement whatever the sampling (`LayerTransform.samePlacement(as:)`).
    public func samePlacement(as o: CompTransform) -> Bool {
        originX == o.originX && originY == o.originY && width == o.width && height == o.height && rotation == o.rotation
            && flipX == o.flipX && flipY == o.flipY
    }
}

public struct CompGuide: Decodable, Sendable {
    public enum Axis: String, Decodable, Sendable { case horizontal, vertical }
    public var id: UUID
    public var axis: Axis
    /// Document pixels: y for a horizontal guide, x for a vertical one.
    public var position: Double
}

/// A straight sRGB colour, 0–1 per channel (`AdjustmentColor`).
public struct CompColor: Decodable, Sendable, Equatable {
    public var red: Double, green: Double, blue: Double
    public init(red: Double, green: Double, blue: Double) { self.red = red; self.green = green; self.blue = blue }
    public var isValid: Bool { [red, green, blue].allSatisfy { $0.isFinite && (0 ... 1).contains($0) } }
}

// MARK: Adjustments

/// `LayerAdjustment`: one kind plus the settings of every kind, each optional.
public struct CompAdjustment: Decodable, Sendable {
    public enum Kind: String, Sendable, CaseIterable {
        case hsv = "Hue/Saturation", levels = "Levels", curves = "Curves", exposure = "Exposure", gradientMap = "Gradient Map"
        case grain = "Grain", addNoise = "Add Noise", gaussianBlur = "Gaussian Blur", motionBlur = "Motion Blur", invert = "Invert"
        case blackWhite = "Black & White", colorBalance = "Color Balance"

        /// Kinds version 9 added (they sample neighbouring pixels).
        public var needsVersion9: Bool { self == .gaussianBlur || self == .motionBlur || self == .addNoise }
    }

    /// The kind's name as stored; `kind` is nil for a name this reader doesn't know.
    public var kindName: String
    public var kind: Kind? { Kind(rawValue: kindName) }
    public var hue: Double, saturation: Double, lightness: Double
    public var colorize: Bool
    public var hsvSettings: CompHueSaturation?
    public var levels: [CompLevelRange]
    public var curves: [[CompCurvePoint]]
    public var exposure: CompExposure?
    public var gradientMap: CompGradientMap?
    public var grain: CompGrain?
    public var blackWhite: CompBlackWhite?
    public var colorBalance: CompColorBalance?
    public var blurRadius: Double?
    public var motionAngle: Double?
    public var motionDistance: Double?
    public var noiseAmount: Double?
    public var noiseGaussian: Bool?
    public var noiseMonochromatic: Bool?
    public var noiseSeed: UInt32?

    enum CodingKeys: String, CodingKey {
        case kind, hue, saturation, lightness, colorize, hsvSettings, levels, curves, exposureSettings, gradientMapSettings, grainSettings
        case blackWhiteSettings, colorBalanceSettings, blurRadius, motionAngle, motionDistance, noiseAmount, noiseGaussian
        case noiseMonochromatic, noiseSeed
    }

    private struct LevelsBox: Decodable { var ranges: [CompLevelRange]? }
    private struct CurvesBox: Decodable { var channels: [[CompCurvePoint]]? }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kindName = try c.decode(String.self, forKey: .kind)
        hue = try c.decodeIfPresent(Double.self, forKey: .hue) ?? 0
        saturation = try c.decodeIfPresent(Double.self, forKey: .saturation) ?? 0
        lightness = try c.decodeIfPresent(Double.self, forKey: .lightness) ?? 0
        colorize = try c.decodeIfPresent(Bool.self, forKey: .colorize) ?? false
        hsvSettings = try c.decodeIfPresent(CompHueSaturation.self, forKey: .hsvSettings)
        levels = try c.decodeIfPresent(LevelsBox.self, forKey: .levels)?.ranges ?? Array(repeating: CompLevelRange(), count: 4)
        curves = try c.decodeIfPresent(CurvesBox.self, forKey: .curves)?.channels ?? Array(repeating: CompCurvePoint.line, count: 4)
        exposure = try c.decodeIfPresent(CompExposure.self, forKey: .exposureSettings)
        gradientMap = try c.decodeIfPresent(CompGradientMap.self, forKey: .gradientMapSettings)
        grain = try c.decodeIfPresent(CompGrain.self, forKey: .grainSettings)
        blackWhite = try c.decodeIfPresent(CompBlackWhite.self, forKey: .blackWhiteSettings)
        colorBalance = try c.decodeIfPresent(CompColorBalance.self, forKey: .colorBalanceSettings)
        blurRadius = try c.decodeIfPresent(Double.self, forKey: .blurRadius)
        motionAngle = try c.decodeIfPresent(Double.self, forKey: .motionAngle)
        motionDistance = try c.decodeIfPresent(Double.self, forKey: .motionDistance)
        noiseAmount = try c.decodeIfPresent(Double.self, forKey: .noiseAmount)
        noiseGaussian = try c.decodeIfPresent(Bool.self, forKey: .noiseGaussian)
        noiseMonochromatic = try c.decodeIfPresent(Bool.self, forKey: .noiseMonochromatic)
        noiseSeed = try c.decodeIfPresent(UInt32.self, forKey: .noiseSeed)
    }

    /// The Hue/Saturation settings in force (`resolvedHSV`): the range-aware record, else the
    /// older master-only fields.
    public var resolvedHSV: CompHueSaturation {
        hsvSettings ?? CompHueSaturation(master: CompRangeAdjustment(hue: hue, saturation: saturation, lightness: lightness), colorize: colorize)
    }

    /// `LayerAdjustment.isValid`, for the settings this reader maps.
    public var isValid: Bool {
        func finite(_ v: Double?, _ r: ClosedRange<Double>) -> Bool { v.map { $0.isFinite && r.contains($0) } ?? true }
        let hsv = resolvedHSV
        return finite(hue, -360 ... 360) && finite(saturation, -100 ... 100) && finite(lightness, -100 ... 100)
            && hsv.adjustments.values.allSatisfy { finite($0.hue, -360 ... 360) && finite($0.saturation, -100 ... 100) && finite($0.lightness, -100 ... 100) }
            && hsv.bands.values.allSatisfy { $0.handles.allSatisfy(\.isFinite) }
            && levels.count == 4 && levels.allSatisfy(\.isValid)
            && curves.count == 4 && curves.allSatisfy(CompCurvePoint.isValidCurve)
            && (exposure?.isValid ?? true) && (gradientMap?.isValid ?? true) && (grain?.isValid ?? true)
            && (blackWhite?.isValid ?? true) && (colorBalance?.isValid ?? true)
            && finite(blurRadius, 0.1 ... 250) && finite(motionAngle, -90 ... 90) && finite(motionDistance, 1 ... 2000)
            && finite(noiseAmount, 0.1 ... 400)
    }
}

/// Compositor's Hue/Saturation colour ranges.
public enum CompColorRange: String, Sendable, CaseIterable, CodingKey {
    case master = "Master", reds = "Reds", yellows = "Yellows", greens = "Greens", cyans = "Cyans", blues = "Blues", magentas = "Magentas"

    /// Photoshop's starting band (falloff start, range start, range end, falloff end).
    public var defaultBand: CompHueBand {
        switch self {
        case .master: CompHueBand(falloffStart: 0, rangeStart: 0, rangeEnd: 360, falloffEnd: 360)
        case .reds: CompHueBand(falloffStart: 315, rangeStart: 345, rangeEnd: 15, falloffEnd: 45)
        case .yellows: CompHueBand(falloffStart: 15, rangeStart: 45, rangeEnd: 75, falloffEnd: 105)
        case .greens: CompHueBand(falloffStart: 75, rangeStart: 105, rangeEnd: 135, falloffEnd: 165)
        case .cyans: CompHueBand(falloffStart: 135, rangeStart: 165, rangeEnd: 195, falloffEnd: 225)
        case .blues: CompHueBand(falloffStart: 195, rangeStart: 225, rangeEnd: 255, falloffEnd: 285)
        case .magentas: CompHueBand(falloffStart: 255, rangeStart: 285, rangeEnd: 315, falloffEnd: 345)
        }
    }

    public static let colorRanges: [CompColorRange] = [.reds, .yellows, .greens, .cyans, .blues, .magentas]
}

public struct CompHueBand: Decodable, Sendable, Equatable {
    public var falloffStart: Double, rangeStart: Double, rangeEnd: Double, falloffEnd: Double
    public var handles: [Double] { [falloffStart, rangeStart, rangeEnd, falloffEnd] }
}

public struct CompRangeAdjustment: Decodable, Sendable, Equatable {
    public var hue: Double = 0, saturation: Double = 0, lightness: Double = 0
    public init(hue: Double = 0, saturation: Double = 0, lightness: Double = 0) { self.hue = hue; self.saturation = saturation; self.lightness = lightness }
    enum CodingKeys: String, CodingKey { case hue, saturation, lightness }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hue = try c.decodeIfPresent(Double.self, forKey: .hue) ?? 0
        saturation = try c.decodeIfPresent(Double.self, forKey: .saturation) ?? 0
        lightness = try c.decodeIfPresent(Double.self, forKey: .lightness) ?? 0
    }
}

/// `HueSaturationSettings`: per-range values and bands. Its dictionaries are keyed by an enum, which
/// `JSONEncoder` writes as a flat `[key, value, key, value, …]` array; an object is read too.
public struct CompHueSaturation: Decodable, Sendable {
    public var range: CompColorRange
    public var colorize: Bool
    public var invertRange: Bool
    public var adjustments: [CompColorRange: CompRangeAdjustment]
    public var bands: [CompColorRange: CompHueBand]

    public init(master: CompRangeAdjustment, colorize: Bool) {
        range = .master
        self.colorize = colorize
        invertRange = false
        adjustments = [.master: master]
        bands = Dictionary(uniqueKeysWithValues: CompColorRange.allCases.map { ($0, $0.defaultBand) })
    }

    enum CodingKeys: String, CodingKey { case range, colorize, invertRange, adjustments, bands }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        range = try c.decodeIfPresent(String.self, forKey: .range).flatMap(CompColorRange.init(rawValue:)) ?? .master
        colorize = try c.decodeIfPresent(Bool.self, forKey: .colorize) ?? false
        invertRange = try c.decodeIfPresent(Bool.self, forKey: .invertRange) ?? false
        adjustments = try Self.map(c, .adjustments) ?? [:]
        var b = Dictionary(uniqueKeysWithValues: CompColorRange.allCases.map { ($0, $0.defaultBand) })
        for (k, v) in try Self.map(c, .bands) as [CompColorRange: CompHueBand]? ?? [:] { b[k] = v }
        bands = b
    }

    private static func map<V: Decodable>(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) throws -> [CompColorRange: V]? {
        guard c.contains(key), try !c.decodeNil(forKey: key) else { return nil }
        if var u = try? c.nestedUnkeyedContainer(forKey: key) {
            var out: [CompColorRange: V] = [:]
            while !u.isAtEnd {
                let name = try u.decode(String.self)
                let value = try u.decode(V.self)
                if let r = CompColorRange(rawValue: name) { out[r] = value }
            }
            return out
        }
        let k = try c.nestedContainer(keyedBy: CompColorRange.self, forKey: key)
        var out: [CompColorRange: V] = [:]
        for r in k.allKeys { out[r] = try k.decode(V.self, forKey: r) }
        return out
    }

    public var isIdentity: Bool { !colorize && adjustments.values.allSatisfy { $0 == CompRangeAdjustment() } }
}

/// One Levels record on 0–255 (`LevelRange`).
public struct CompLevelRange: Decodable, Sendable, Equatable {
    public var black: Double = 0, gamma: Double = 1, white: Double = 255, outputBlack: Double = 0, outputWhite: Double = 255
    public init() {}
    enum CodingKeys: String, CodingKey { case black, gamma, white, outputBlack, outputWhite }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        black = try c.decodeIfPresent(Double.self, forKey: .black) ?? 0
        gamma = try c.decodeIfPresent(Double.self, forKey: .gamma) ?? 1
        white = try c.decodeIfPresent(Double.self, forKey: .white) ?? 255
        outputBlack = try c.decodeIfPresent(Double.self, forKey: .outputBlack) ?? 0
        outputWhite = try c.decodeIfPresent(Double.self, forKey: .outputWhite) ?? 255
    }
    /// `LevelRange.normalized`.
    public var normalized: CompLevelRange {
        func clamp(_ n: Double, _ r: ClosedRange<Double>, _ fallback: Double) -> Double { n.isFinite ? min(r.upperBound, max(r.lowerBound, n)) : fallback }
        var o = self
        o.black = clamp(black, 0 ... 254, 0)
        o.white = clamp(white, (o.black + 1) ... 255, 255)
        o.gamma = clamp(gamma, 0.1 ... 9.99, 1)
        o.outputBlack = clamp(outputBlack, 0 ... 255, 0)
        o.outputWhite = clamp(outputWhite, 0 ... 255, 255)
        return o
    }
    /// Compositor stores ranges normalized and refuses any other.
    public var isValid: Bool { self == normalized }
}

public struct CompCurvePoint: Decodable, Sendable, Equatable {
    public var x: Double, y: Double
    public static let line = [CompCurvePoint(x: 0, y: 0), CompCurvePoint(x: 255, y: 255)]
    /// `CurvesSettings.isValid` for one channel.
    public static func isValidCurve(_ p: [CompCurvePoint]) -> Bool {
        (2 ... 32).contains(p.count) && p.first?.x == 0 && p.last?.x == 255
            && p.allSatisfy { $0.x.isFinite && $0.y.isFinite && (0 ... 255).contains($0.x) && (0 ... 255).contains($0.y) }
            && zip(p, p.dropFirst()).allSatisfy { $0.x < $1.x }
    }
}

public struct CompExposure: Decodable, Sendable {
    public var exposure: Double = 0, offset: Double = 0, gamma: Double = 1
    enum CodingKeys: String, CodingKey { case exposure, offset, gamma }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        exposure = try c.decodeIfPresent(Double.self, forKey: .exposure) ?? 0
        offset = try c.decodeIfPresent(Double.self, forKey: .offset) ?? 0
        gamma = try c.decodeIfPresent(Double.self, forKey: .gamma) ?? 1
    }
    public var isValid: Bool { (-20 ... 20).contains(exposure) && (-0.5 ... 0.5).contains(offset) && (0.01 ... 9.99).contains(gamma) }
}

public struct CompGradientMap: Decodable, Sendable {
    public var shadows = CompColor(red: 0, green: 0, blue: 0)
    public var highlights = CompColor(red: 1, green: 1, blue: 1)
    public var reversed = false
    enum CodingKeys: String, CodingKey { case shadows, highlights, reversed }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        shadows = try c.decodeIfPresent(CompColor.self, forKey: .shadows) ?? shadows
        highlights = try c.decodeIfPresent(CompColor.self, forKey: .highlights) ?? highlights
        reversed = try c.decodeIfPresent(Bool.self, forKey: .reversed) ?? false
    }
    public var isValid: Bool { shadows.isValid && highlights.isValid }
}

public struct CompGrain: Decodable, Sendable {
    public var amount: Double = 25, size: Double = 1.5, roughness: Double = 50
    public var seed: UInt32 = 0
    enum CodingKeys: String, CodingKey { case amount, size, roughness, seed }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        amount = try c.decodeIfPresent(Double.self, forKey: .amount) ?? 25
        size = try c.decodeIfPresent(Double.self, forKey: .size) ?? 1.5
        roughness = try c.decodeIfPresent(Double.self, forKey: .roughness) ?? 50
        seed = try c.decodeIfPresent(UInt32.self, forKey: .seed) ?? 0
    }
    public var isValid: Bool { (0 ... 100).contains(amount) && (0.5 ... 20).contains(size) && (0 ... 100).contains(roughness) }
}

public struct CompBlackWhite: Decodable, Sendable {
    public var reds: Double = 40, yellows: Double = 60, greens: Double = 40, cyans: Double = 60, blues: Double = 20, magentas: Double = 80
    public var tint = false
    public var tintHue: Double = 40, tintSaturation: Double = 20
    enum CodingKeys: String, CodingKey { case reds, yellows, greens, cyans, blues, magentas, tint, tintHue, tintSaturation }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        reds = try c.decodeIfPresent(Double.self, forKey: .reds) ?? 40
        yellows = try c.decodeIfPresent(Double.self, forKey: .yellows) ?? 60
        greens = try c.decodeIfPresent(Double.self, forKey: .greens) ?? 40
        cyans = try c.decodeIfPresent(Double.self, forKey: .cyans) ?? 60
        blues = try c.decodeIfPresent(Double.self, forKey: .blues) ?? 20
        magentas = try c.decodeIfPresent(Double.self, forKey: .magentas) ?? 80
        tint = try c.decodeIfPresent(Bool.self, forKey: .tint) ?? false
        tintHue = try c.decodeIfPresent(Double.self, forKey: .tintHue) ?? 40
        tintSaturation = try c.decodeIfPresent(Double.self, forKey: .tintSaturation) ?? 20
    }
    public var weights: [Double] { [reds, yellows, greens, cyans, blues, magentas] }
    public var isValid: Bool {
        weights.allSatisfy { $0.isFinite && (-200 ... 300).contains($0) } && tintHue.isFinite && (0 ... 360).contains(tintHue)
            && tintSaturation.isFinite && (0 ... 100).contains(tintSaturation)
    }
}

public struct CompColorBalance: Decodable, Sendable {
    /// Shadows, midtones, highlights; each (cyan–red, magenta–green, yellow–blue), −100…100.
    public var shadows: [Double], midtones: [Double], highlights: [Double]
    public var preserveLuminosity: Bool
    enum CodingKeys: String, CodingKey {
        case shadowCyanRed, shadowMagentaGreen, shadowYellowBlue, midCyanRed, midMagentaGreen, midYellowBlue
        case highlightCyanRed, highlightMagentaGreen, highlightYellowBlue, preserveLuminosity
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v(_ k: CodingKeys) throws -> Double { try c.decodeIfPresent(Double.self, forKey: k) ?? 0 }
        shadows = [try v(.shadowCyanRed), try v(.shadowMagentaGreen), try v(.shadowYellowBlue)]
        midtones = [try v(.midCyanRed), try v(.midMagentaGreen), try v(.midYellowBlue)]
        highlights = [try v(.highlightCyanRed), try v(.highlightMagentaGreen), try v(.highlightYellowBlue)]
        preserveLuminosity = try c.decodeIfPresent(Bool.self, forKey: .preserveLuminosity) ?? true
    }
    public var isValid: Bool { (shadows + midtones + highlights).allSatisfy { $0.isFinite && (-100 ... 100).contains($0) } }
}

// MARK: Effects

/// `LayerEffects`: up to six effects, each optional, sizes in layer pixels.
public struct CompEffects: Decodable, Sendable {
    public struct Stroke: Decodable, Sendable {
        public var enabled: Bool?
        public var size: Double = 4
        public var color = CompColor(red: 0, green: 0, blue: 0)
        public var opacity: Double = 1
        public var inside = false
    }
    public struct Shadow: Decodable, Sendable {
        public var enabled: Bool?
        /// Degrees counter-clockwise from the right, where the light comes from.
        public var angle: Double = 90
        public var distance: Double
        public var blur: Double
        public var color = CompColor(red: 0, green: 0, blue: 0)
        public var opacity: Double = 0.5
    }
    public struct Overlay: Decodable, Sendable {
        public var enabled: Bool?
        public var color = CompColor(red: 0, green: 0, blue: 0)
        public var opacity: Double = 1
    }
    public struct Glow: Decodable, Sendable {
        public var enabled: Bool?
        public var size: Double
        public var color = CompColor(red: 1, green: 1, blue: 1)
        public var opacity: Double = 0.75
    }

    public var stroke: Stroke?
    public var shadow: Shadow?
    public var colorOverlay: Overlay?
    public var innerShadow: Shadow?
    public var outerGlow: Glow?
    public var innerGlow: Glow?

    enum CodingKeys: String, CodingKey { case stroke, shadow, colorOverlay, innerShadow, outerGlow, innerGlow }
    enum FieldKeys: String, CodingKey { case enabled, size, red, green, blue, opacity, inside, angle, distance, blur }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func fields(_ k: CodingKeys) throws -> KeyedDecodingContainer<FieldKeys>? {
            guard c.contains(k), try !c.decodeNil(forKey: k) else { return nil }
            return try c.nestedContainer(keyedBy: FieldKeys.self, forKey: k)
        }
        func color(_ f: KeyedDecodingContainer<FieldKeys>, _ d: Double) throws -> CompColor {
            CompColor(red: try f.decodeIfPresent(Double.self, forKey: .red) ?? d, green: try f.decodeIfPresent(Double.self, forKey: .green) ?? d,
                      blue: try f.decodeIfPresent(Double.self, forKey: .blue) ?? d)
        }
        func num(_ f: KeyedDecodingContainer<FieldKeys>, _ k: FieldKeys, _ d: Double) throws -> Double { try f.decodeIfPresent(Double.self, forKey: k) ?? d }
        func readShadow(_ k: CodingKeys, _ dist: Double, _ blur: Double) throws -> Shadow? {
            guard let f = try fields(k) else { return nil }
            return Shadow(enabled: try f.decodeIfPresent(Bool.self, forKey: .enabled), angle: try num(f, .angle, 90),
                          distance: try num(f, .distance, dist), blur: try num(f, .blur, blur), color: try color(f, 0), opacity: try num(f, .opacity, 0.5))
        }
        func readGlow(_ k: CodingKeys, _ size: Double) throws -> Glow? {
            guard let f = try fields(k) else { return nil }
            return Glow(enabled: try f.decodeIfPresent(Bool.self, forKey: .enabled), size: try num(f, .size, size), color: try color(f, 1),
                        opacity: try num(f, .opacity, 0.75))
        }
        if let f = try fields(.stroke) {
            stroke = Stroke(enabled: try f.decodeIfPresent(Bool.self, forKey: .enabled), size: try num(f, .size, 4), color: try color(f, 0),
                            opacity: try num(f, .opacity, 1), inside: try f.decodeIfPresent(Bool.self, forKey: .inside) ?? false)
        }
        shadow = try readShadow(.shadow, 20, 20)
        innerShadow = try readShadow(.innerShadow, 10, 10)
        if let f = try fields(.colorOverlay) {
            colorOverlay = Overlay(enabled: try f.decodeIfPresent(Bool.self, forKey: .enabled), color: try color(f, 0), opacity: try num(f, .opacity, 1))
        }
        outerGlow = try readGlow(.outerGlow, 20)
        innerGlow = try readGlow(.innerGlow, 10)
    }

    public var isEmpty: Bool { stroke == nil && shadow == nil && colorOverlay == nil && innerShadow == nil && outerGlow == nil && innerGlow == nil }

    /// `LayerEffects.isValid`.
    public var isValid: Bool {
        func unit(_ v: Double) -> Bool { v.isFinite && (0 ... 1).contains(v) }
        func shadowOK(_ s: Shadow) -> Bool {
            [s.angle, s.distance, s.blur].allSatisfy(\.isFinite) && (-360 ... 360).contains(s.angle) && (0 ... 5000).contains(s.distance)
                && (0 ... 500).contains(s.blur) && unit(s.opacity) && s.color.isValid
        }
        func glowOK(_ g: Glow) -> Bool { g.size.isFinite && (0 ... 500).contains(g.size) && unit(g.opacity) && g.color.isValid }
        return (stroke.map { $0.size.isFinite && (0 ... 500).contains($0.size) && unit($0.opacity) && $0.color.isValid } ?? true)
            && (shadow.map(shadowOK) ?? true) && (innerShadow.map(shadowOK) ?? true)
            && (colorOverlay.map { unit($0.opacity) && $0.color.isValid } ?? true)
            && (outerGlow.map(glowOK) ?? true) && (innerGlow.map(glowOK) ?? true)
    }
}

// MARK: Shape and text metadata

/// `LayerShapeStyle`: what the Shape tool drew, so the shape can be redrawn at a new size.
public struct CompShapeStyle: Decodable, Sendable {
    public enum Kind: String, Decodable, Sendable { case rectangle = "Rectangle", ellipse = "Ellipse", line = "Line" }
    public var kind: Kind
    public var color: CompColor
    /// Document pixels.
    public var cornerRadius: Double
    public var lineWidth: Double?
    /// A line's ends as fractions of the layer's box.
    public var start: CompPair?
    public var end: CompPair?

    enum CodingKeys: String, CodingKey { case kind, red, green, blue, cornerRadius, lineWidth, start, end }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(Kind.self, forKey: .kind)
        color = CompColor(red: try c.decodeIfPresent(Double.self, forKey: .red) ?? 0, green: try c.decodeIfPresent(Double.self, forKey: .green) ?? 0,
                          blue: try c.decodeIfPresent(Double.self, forKey: .blue) ?? 0)
        cornerRadius = try c.decodeIfPresent(Double.self, forKey: .cornerRadius) ?? 0
        lineWidth = try c.decodeIfPresent(Double.self, forKey: .lineWidth)
        start = try c.decodeIfPresent(CompPair.self, forKey: .start)
        end = try c.decodeIfPresent(CompPair.self, forKey: .end)
    }
}

/// `LayerTextStyle`: editable text over a PNG that stays its display and export fallback.
public struct CompTextStyle: Decodable, Sendable {
    public enum Alignment: String, Decodable, Sendable { case left = "Left", center = "Center", right = "Right" }
    public struct ColorRun: Decodable, Sendable { public var location: Int, length: Int, red: Double, green: Double, blue: Double }
    public struct FontRun: Decodable, Sendable { public var location: Int, length: Int; public var fontName: String }

    public var content: String
    /// PostScript name.
    public var fontName: String
    /// Pixels.
    public var fontSize: Double
    public var color: CompColor
    public var alignment: Alignment
    public var tracking: Double
    /// Baseline to baseline in layer pixels; 0 = auto (120 % of the size).
    public var leading: Double
    /// Paragraph bounds in layer pixels; nil for point text.
    public var boxSize: CompPair?
    /// UTF-16 offsets into `content` (v10).
    public var colorRuns: [ColorRun]?
    /// UTF-16 offsets into `content` (v11).
    public var fontRuns: [FontRun]?

    enum CodingKeys: String, CodingKey { case content, fontName, fontSize, red, green, blue, alignment, tracking, leading, lineSpacing, boxSize, colorRuns, fontRuns }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        content = try c.decodeIfPresent(String.self, forKey: .content) ?? "Text"
        fontName = try c.decodeIfPresent(String.self, forKey: .fontName) ?? "Helvetica"
        fontSize = try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? 72
        color = CompColor(red: try c.decodeIfPresent(Double.self, forKey: .red) ?? 0, green: try c.decodeIfPresent(Double.self, forKey: .green) ?? 0,
                          blue: try c.decodeIfPresent(Double.self, forKey: .blue) ?? 0)
        alignment = (try? c.decodeIfPresent(Alignment.self, forKey: .alignment)) ?? .left
        tracking = try c.decodeIfPresent(Double.self, forKey: .tracking) ?? 0
        leading = try c.decodeIfPresent(Double.self, forKey: .leading) ?? c.decodeIfPresent(Double.self, forKey: .lineSpacing) ?? 0
        boxSize = try c.decodeIfPresent(CompPair.self, forKey: .boxSize)
        colorRuns = try c.decodeIfPresent([ColorRun].self, forKey: .colorRuns)
        fontRuns = try c.decodeIfPresent([FontRun].self, forKey: .fontRuns)
    }

    /// `LayerTextStyle.isValid` (runs sorted, non-overlapping, inside the content).
    public var isValid: Bool {
        let n = content.utf16.count
        func runsOK(_ runs: [(Int, Int)]?) -> Bool {
            guard let runs else { return true }
            var end = 0
            for (loc, len) in runs {
                guard loc >= end, len > 0, loc <= Int.max - len else { return false }
                end = loc + len
            }
            return !runs.isEmpty && end <= n
        }
        let box = boxSize.map { [$0.a, $0.b].allSatisfy { $0.isFinite && (16 ... 30_000).contains($0) } && $0.a * $0.b <= 200_000_000 } ?? true
        return n <= 100_000 && box && fontSize.isFinite && (1 ... 2000).contains(fontSize) && color.isValid
            && tracking.isFinite && (-100 ... 1000).contains(tracking) && leading.isFinite && (0 ... 5000).contains(leading)
            && runsOK(colorRuns?.map { ($0.location, $0.length) }) && runsOK(fontRuns?.map { ($0.location, $0.length) })
            && (colorRuns ?? []).allSatisfy { CompColor(red: $0.red, green: $0.green, blue: $0.blue).isValid }
            && (fontRuns ?? []).allSatisfy { !$0.fontName.isEmpty && $0.fontName.count <= 200 && !$0.fontName.contains(where: \.isNewline) }
    }
}

// MARK: Validation (`ProjectStore.validate`)

extension CompManifest {
    /// Longest canvas, layer or mask side Compositor allows (`DocumentLimits.maxSide`).
    public static let maxSide = 30_000
    /// Layers in one project.
    public static let maxLayers = 10_000
    /// Image pixels (and, separately, mask pixels) one project may hold: Compositor scales its
    /// budget to the Mac's memory, never above this.
    public static let pixelBudget = 800_000_000
    /// Largest `manifest.json` and largest image asset.
    public static let maxManifestBytes = 4 << 20
    public static let maxAssetBytes = 512 << 20

    /// Refuses a manifest Compositor itself would refuse, naming the rule. Every version gate of
    /// `ProjectStore.validate`, `LayerHierarchy.validate`, `LiveMaskGraph.validate` and the guide
    /// check is here.
    public func validate() throws(CompError) {
        guard format == Self.formatID else { throw .invalid("format is \"\(format)\", not \(Self.formatID)") }
        guard Self.supported.contains(version) else { throw .version(version) }
        guard colorSpace == "sRGB" else { throw .invalid("colour space \"\(colorSpace)\" (Compositor documents are sRGB)") }
        if let r = resolution, !(r.isFinite && (1 ... 9600).contains(r)) { throw .invalid("resolution \(r) is outside 1–9600 ppi") }
        guard (1 ... Self.maxSide).contains(width), (1 ... Self.maxSide).contains(height) else {
            throw .tooLarge("canvas \(width) × \(height) exceeds \(Self.maxSide) px a side")
        }
        guard layers.count <= Self.maxLayers else { throw .tooLarge("\(layers.count) layers (at most \(Self.maxLayers))") }
        let v = version
        for l in layers {
            let at = "layer \"\(l.name)\""
            if let t = l.text {
                guard t.isValid else { throw .invalid("\(at): invalid text metadata") }
                guard t.colorRuns == nil || v >= 10 else { throw .invalid("\(at): per-letter colours need version 10") }
                guard t.fontRuns == nil || v >= 11 else { throw .invalid("\(at): per-letter faces need version 11") }
                guard l.imageFile != nil, !l.group, l.adjustment == nil else { throw .invalid("\(at): text metadata on a layer without its image") }
            }
            if let a = l.adjustment {
                guard v >= 7 else { throw .invalid("\(at): adjustment layers need version 7") }
                guard !l.group, l.imageFile == nil else { throw .invalid("\(at): an adjustment layer can't be a group or hold an image") }
                guard let kind = a.kind else { throw .invalid("\(at): unknown adjustment kind \"\(a.kindName)\"") }
                guard a.isValid else { throw .invalid("\(at): adjustment settings out of range") }
                guard !kind.needsVersion9 || v >= 9 else { throw .invalid("\(at): \(kind.rawValue) needs version 9") }
            }
            if let m = l.maskFile {
                guard v >= (l.group ? 6 : 4) else { throw .invalid("\(at): \(l.group ? "folder masks need version 6" : "layer masks need version 4")") }
                guard m == "\(l.id.uuidString).mask.png" else { throw .invalid("\(at): mask file must be \(l.id.uuidString).mask.png") }
            }
            guard l.maskEnabled == nil || l.maskFile != nil else { throw .invalid("\(at): maskEnabled without a mask") }
            if let p = l.maskPlacement { guard p.isValid, l.maskFile != nil else { throw .invalid("\(at): invalid mask placement") } }
            let opacity = l.opacity ?? 1, blend = l.blendMode ?? "Normal"
            guard opacity.isFinite, (0 ... 1).contains(opacity) else { throw .invalid("\(at): opacity \(opacity) outside 0–1") }
            guard v >= 3 || (opacity == 1 && blend == "Normal") else { throw .invalid("\(at): opacity and blend modes need version 3") }
            guard !l.group || (blend == "Normal" && (v >= 8 || opacity == 1)) else {
                throw .invalid("\(at): a folder's blend mode stays Normal, and its own opacity needs version 8")
            }
            if let e = l.effects, !e.isValid { throw .invalid("\(at): effect settings out of range") }
        }
        try validateHierarchy()
        try validateLiveMasks()
        if v < 5, layers.contains(where: { $0.maskSourceID != nil }) { throw .invalid("clipping masks need version 5") }
        if v == 1, layers.contains(where: { $0.parentID != nil || $0.group }) { throw .invalid("folders need version 2") }
        var ids = Set<UUID>()
        for l in layers {
            guard ids.insert(l.id).inserted else { throw .invalid("layer id \(l.id.uuidString) repeats") }
            guard l.transform.isValid else { throw .invalid("layer \"\(l.name)\": invalid transform") }
            guard !l.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, l.name.utf8.count <= 16_384 else {
                throw .invalid("a layer name is empty or longer than 16 KiB")
            }
            if let f = l.imageFile {
                guard f == "\(l.id.uuidString).png" || (v >= 13 && f == "\(l.id.uuidString).exr") else {
                    throw .invalid("layer \"\(l.name)\": image file must be \(l.id.uuidString).png\(v >= 13 ? " or .exr" : "")")
                }
            }
        }
        if let a = activeLayerID, !ids.contains(a) { throw .invalid("the active layer \(a.uuidString) doesn't exist") }
        try validateGuides()
    }

    /// `LayerHierarchy.validate`: parents exist and are folders, no cycles, at most 64 levels.
    func validateHierarchy() throws(CompError) {
        var byID: [UUID: CompLayer] = [:]
        for l in layers {
            guard byID.updateValue(l, forKey: l.id) == nil else { throw .invalid("layer id \(l.id.uuidString) repeats") }
            guard !l.group || l.imageFile == nil else { throw .invalid("folder \"\(l.name)\" holds an image") }
        }
        for l in layers {
            var seen: Set<UUID> = [l.id]
            var parent = l.parentID
            while let id = parent {
                guard seen.count <= 64, seen.insert(id).inserted, let node = byID[id], node.group else {
                    throw .invalid("layer \"\(l.name)\": its folder is missing, not a folder, nested past 64 levels or circular")
                }
                parent = node.parentID
            }
            if l.group, seen.count > 64 { throw .invalid("folder \"\(l.name)\" is nested past 64 levels") }
        }
    }

    /// `LiveMaskGraph.validate`: sources exist, aren't folders or adjustments, no cycles, chains
    /// under 256.
    func validateLiveMasks() throws(CompError) {
        var byID: [UUID: CompLayer] = [:]
        for l in layers { byID[l.id] = l }
        for l in layers {
            var path = Set<UUID>()
            var current: UUID? = l.id
            while let id = current {
                guard path.count < 256, path.insert(id).inserted, let r = byID[id] else {
                    throw .invalid("layer \"\(l.name)\": its clipping chain is missing, circular or longer than 256")
                }
                if let s = r.maskSourceID {
                    guard !r.group, let src = byID[s], !src.group, src.adjustment == nil else {
                        throw .invalid("layer \"\(r.name)\": clipped to a folder, an adjustment or a missing layer")
                    }
                }
                current = r.maskSourceID
            }
        }
    }

    func validateGuides() throws(CompError) {
        let gs = guides ?? []
        if version < 8 {
            guard gs.isEmpty else { throw .invalid("guides need version 8") }
            return
        }
        guard gs.count <= 1000 else { throw .tooLarge("\(gs.count) guides (at most 1,000)") }
        var ids = Set<UUID>()
        for g in gs {
            guard ids.insert(g.id).inserted, g.position.isFinite, abs(g.position) <= 1_000_000 else { throw .invalid("a guide repeats or lies out of range") }
        }
    }
}

/// Why a `.comp` package was refused (Compositor's `ProjectError` cases, with the rule named).
public enum CompError: Error, Equatable, Sendable, CustomStringConvertible {
    /// Not a Compositor project, or metadata Compositor would refuse.
    case invalid(String)
    /// A format version outside 1–13.
    case version(Int)
    /// An image inside the package is missing, damaged or not what its name says.
    case missingImage(String)
    /// Past Compositor's canvas, layer, file-size or pixel limits.
    case tooLarge(String)

    public var description: String {
        switch self {
        case .invalid(let m): "not a valid Compositor project: \(m)"
        case .version(let v): "this project uses format version \(v); versions \(CompManifest.supported.lowerBound)–\(CompManifest.supported.upperBound) are supported"
        case .missingImage(let m): "an image inside the project is missing or damaged: \(m)"
        case .tooLarge(let m): "the project exceeds Compositor's limits: \(m)"
        }
    }
}
