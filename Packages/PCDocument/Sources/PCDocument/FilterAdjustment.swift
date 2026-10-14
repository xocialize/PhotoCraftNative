// Filter adjustment layers (AB-T-0258): Grain, Add Noise, Gaussian Blur and Motion Blur over the
// composite beneath them, live. New; no photocraft counterpart. The kinds, their settings, ranges
// and defaults are Compositor's (Document/LayerAdjustment.swift, ImageAdjustments.swift,
// Filters.swift; Compositor is MIT, © 2026 Wonder Assembly LLC). Evaluation lives in the
// compositor (PCRender, Filters.swift there).

import Foundation

/// A filter an adjustment layer applies to the composite beneath it, as any adjustment applies its
/// colour change: within its group (or to its clipping base), inside its mask, at its opacity and in
/// its blend mode. The blurs read the backdrop around each pixel; Grain and Add Noise add a pattern
/// fixed in document space by their seed, so every tile, band and level of detail draws the same one.
///
/// Photoshop has no such layer (only the destructive filters and smart filters of the same names):
/// a PSD keeps none of them, and `.pcraft` writes a document holding one as format 3.
public enum FilterAdjustment: Hashable, Sendable, Codable {
    case grain(Grain)
    case addNoise(AddNoise)
    case gaussianBlur(GaussianBlur)
    case motionBlur(MotionBlur)

    public enum Kind: String, Hashable, Sendable, Codable, CaseIterable {
        case grain, addNoise, gaussianBlur, motionBlur
    }

    /// Film grain: brightness noise, strongest in the midtones, smooth at `size` and roughened by
    /// smaller detail.
    public struct Grain: Hashable, Sendable, Codable {
        public static let amountRange: ClosedRange<Float> = 0...100
        public static let sizeRange: ClosedRange<Float> = 0.5...20
        public static let roughnessRange: ClosedRange<Float> = 0...100
        /// Strength, 0–100.
        public var amount: Float
        /// The grain's scale in document pixels, 0.5–20.
        public var size: Float
        /// How much smaller, irregular detail roughens the grain, 0–100.
        public var roughness: Float
        /// The pattern.
        public var seed: UInt32

        public init(amount: Float = 25, size: Float = 1.5, roughness: Float = 50, seed: UInt32 = 0) {
            self.amount = amount; self.size = size; self.roughness = roughness; self.seed = seed
        }

        enum CodingKeys: String, CodingKey { case amount, size, roughness, seed }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            amount = try c.decode(.amount, or: 25)
            size = try c.decode(.size, or: 1.5)
            roughness = try c.decode(.roughness, or: 50)
            seed = try c.decode(.seed, or: 0)
        }
    }

    /// Photoshop's Add Noise: each pixel's channels moved by a random amount.
    public struct AddNoise: Hashable, Sendable, Codable {
        public static let amountRange: ClosedRange<Float> = 0.1...400
        /// Strength as Photoshop's percentage, 0.1–400.
        public var amount: Float
        /// Gaussian distribution (more speckled) instead of uniform.
        public var gaussian: Bool
        /// Brightness only: the same amount on every channel.
        public var monochromatic: Bool
        /// The pattern.
        public var seed: UInt32

        public init(amount: Float = 10, gaussian: Bool = false, monochromatic: Bool = false, seed: UInt32 = 0) {
            self.amount = amount; self.gaussian = gaussian; self.monochromatic = monochromatic; self.seed = seed
        }

        enum CodingKeys: String, CodingKey { case amount, gaussian, monochromatic, seed }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            amount = try c.decode(.amount, or: 10)
            gaussian = try c.decode(.gaussian, or: false)
            monochromatic = try c.decode(.monochromatic, or: false)
            seed = try c.decode(.seed, or: 0)
        }
    }

    public struct GaussianBlur: Hashable, Sendable, Codable {
        public static let radiusRange: ClosedRange<Float> = 0.1...250
        /// The blur's standard deviation in document pixels, 0.1–250.
        public var radius: Float

        public init(radius: Float = 10) { self.radius = radius }

        enum CodingKeys: String, CodingKey { case radius }

        public init(from decoder: any Decoder) throws {
            radius = try decoder.container(keyedBy: CodingKeys.self).decode(.radius, or: 10)
        }
    }

    /// A streak along `angle` with the spread of an even streak `distance` long.
    public struct MotionBlur: Hashable, Sendable, Codable {
        public static let angleRange: ClosedRange<Float> = -90...90
        public static let distanceRange: ClosedRange<Float> = 1...2000
        /// Direction in degrees, counterclockwise from horizontal as in Photoshop, −90–90.
        public var angle: Float
        /// Streak length in document pixels, 1–2000.
        public var distance: Float

        public init(angle: Float = 0, distance: Float = 10) { self.angle = angle; self.distance = distance }

        enum CodingKeys: String, CodingKey { case angle, distance }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            angle = try c.decode(.angle, or: 0)
            distance = try c.decode(.distance, or: 10)
        }
    }

    public var kind: Kind {
        switch self {
        case .grain: .grain
        case .addNoise: .addNoise
        case .gaussianBlur: .gaussianBlur
        case .motionBlur: .motionBlur
        }
    }

    public var label: String { kind.label }

    /// Whether the filter reads the pixels around each one (the blurs), not each pixel alone.
    public var samplesNeighbours: Bool { kind.samplesNeighbours }

    /// A new filter of `kind` with its default settings; Grain and Add Noise take `seed`.
    public static func defaults(_ kind: Kind, seed: UInt32 = 0) -> FilterAdjustment {
        switch kind {
        case .grain: .grain(Grain(seed: seed))
        case .addNoise: .addNoise(AddNoise(seed: seed))
        case .gaussianBlur: .gaussianBlur(GaussianBlur())
        case .motionBlur: .motionBlur(MotionBlur())
        }
    }

    /// The settings within their ranges, a non-finite one at its default (what a render uses).
    public var clamped: FilterAdjustment {
        func c(_ v: Float, _ r: ClosedRange<Float>, _ fallback: Float) -> Float { v.isFinite ? min(max(v, r.lowerBound), r.upperBound) : fallback }
        switch self {
        case .grain(let g):
            return .grain(Grain(amount: c(g.amount, Grain.amountRange, 25), size: c(g.size, Grain.sizeRange, 1.5),
                                roughness: c(g.roughness, Grain.roughnessRange, 50), seed: g.seed))
        case .addNoise(let n):
            return .addNoise(AddNoise(amount: c(n.amount, AddNoise.amountRange, 10), gaussian: n.gaussian, monochromatic: n.monochromatic, seed: n.seed))
        case .gaussianBlur(let b):
            return .gaussianBlur(GaussianBlur(radius: c(b.radius, GaussianBlur.radiusRange, 10)))
        case .motionBlur(let m):
            return .motionBlur(MotionBlur(angle: c(m.angle, MotionBlur.angleRange, 0), distance: c(m.distance, MotionBlur.distanceRange, 10)))
        }
    }

    // MARK: Codable (serde externally tagged, as `Adjustment`)

    public init(from decoder: any Decoder) throws {
        let v = try TaggedVariant(from: decoder)
        switch v.tag {
        case "Grain": self = .grain(try v.payload())
        case "AddNoise": self = .addNoise(try v.payload())
        case "GaussianBlur": self = .gaussianBlur(try v.payload())
        case "MotionBlur": self = .motionBlur(try v.payload())
        default: throw v.unknown()
        }
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .grain(let p): try Tagged.variant("Grain", p, to: encoder)
        case .addNoise(let p): try Tagged.variant("AddNoise", p, to: encoder)
        case .gaussianBlur(let p): try Tagged.variant("GaussianBlur", p, to: encoder)
        case .motionBlur(let p): try Tagged.variant("MotionBlur", p, to: encoder)
        }
    }
}

extension FilterAdjustment.Kind {
    public var label: String {
        switch self {
        case .grain: "Grain"
        case .addNoise: "Add Noise"
        case .gaussianBlur: "Gaussian Blur"
        case .motionBlur: "Motion Blur"
        }
    }

    public var samplesNeighbours: Bool { self == .gaussianBlur || self == .motionBlur }
}

extension Adjustment {
    /// The filter of a filter adjustment layer; nil for every other adjustment.
    public var asFilter: FilterAdjustment? {
        if case .filter(let f) = self { return f }
        return nil
    }
}
