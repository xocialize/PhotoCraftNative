// Layer Style › Blending Options › Blend If: per-channel value ranges that hide a layer's pixels
// by their own value ("This Layer") or by the value beneath them ("Underlying Layer").
// Port of photocraft-doc (crates/doc/src/blend_if.rs), MIT OR Apache-2.0, © ArtCraft Team and the
// PhotoCraft contributors.
//
// Each slider pair is stored as Photoshop stores it in a PSD layer record's blending ranges: a
// black point and a white point, each split into a low and a high half (Alt-drag in the dialog),
// on the 0...255 scale whatever the document's depth. A value below the black low point or above
// the white high point is hidden; between the two halves of a split point it fades linearly.

/// One Blend If slider pair: `black` = (low, high), `white` = (low, high), all on 0...255.
/// JSON: `{"black":[lo,hi],"white":[lo,hi]}`.
public struct BlendRange: Hashable, Sendable, Codable {
    public var black: SIMD2<UInt8>
    public var white: SIMD2<UInt8>

    public init(black: SIMD2<UInt8>, white: SIMD2<UInt8>) { self.black = black; self.white = white }

    /// Every value blends (the sliders at the ends).
    public static let full = BlendRange(black: SIMD2(0, 0), white: SIMD2(255, 255))

    /// Whether this range hides nothing.
    public var isFull: Bool { self == .full }

    /// From PSD's byte order: black low, black high, white low, white high.
    public init(bytes b: [UInt8]) {
        func at(_ i: Int) -> UInt8 { i < b.count ? b[i] : (i < 2 ? 0 : 255) }
        self.init(black: SIMD2(at(0), at(1)), white: SIMD2(at(2), at(3)))
    }

    /// PSD's byte order (see `init(bytes:)`).
    public var bytes: [UInt8] { [black[0], black[1], white[0], white[1]] }

    /// How much of a pixel with value `v` (0...255, fractional for deep documents) shows: 0 below
    /// the black point or above the white point, 1 between them, and a ramp across a split point.
    /// An unsplit black point at `b` shows `v >= b`; an unsplit white point at `w` shows `v <= w`.
    ///
    /// The split ramp is Photoshop's, measured by PCRender on Photoshop 27.11's own blend-if files:
    /// it spans `hi − lo + 1` levels, `(v − lo + 1) / (hi − lo + 1)` clamped to 0…1 (photocraft used
    /// `(v − lo) / (hi − lo)`; blendif-gray went from 9 % to 0.03 % of pixels off). Identical to
    /// PCRender's `Masks.rangeWeight`, so the model and the compositor agree.
    public func weight(_ v: Float) -> Float {
        func ramp(_ lo: UInt8, _ hi: UInt8, _ x: Float) -> Float {
            let (lo, hi) = (Float(lo), Float(hi))
            if hi <= lo { return x >= lo ? 1 : 0 }
            return min(max((x - lo + 1) / (hi - lo + 1), 0), 1)
        }
        let lo = ramp(black[0], black[1], v)
        // Mirror for the white point: 1 at or below its low half, 0 above its high half.
        let hi = ramp(255 - white[1], 255 - white[0], 255 - v)
        return lo * hi
    }
}

extension BlendRange {
    /// The Gray entry's value for an 8-bit RGB pixel as Photoshop computes it:
    /// round(0.30 R + 0.59 G + 0.11 B) on 0...255 (measured with PCRender on Photoshop 27.11).
    public static func gray8(r: Float, g: Float, b: Float) -> Float {
        (0.30 * r + 0.59 * g + 0.11 * b).rounded()
    }
}

/// One Blend If entry: the "This Layer" and "Underlying Layer" slider pairs.
/// JSON: `[thisLayer, underlying]` (photocraft's `[BlendRange; 2]`).
public struct BlendRangePair: Hashable, Sendable, Codable {
    public var this: BlendRange
    public var underlying: BlendRange

    public init(_ this: BlendRange, _ underlying: BlendRange) { self.this = this; self.underlying = underlying }

    public static let full = BlendRangePair(.full, .full)

    public var isFull: Bool { this.isFull && underlying.isFull }

    public init(from decoder: any Decoder) throws {
        var c = try decoder.unkeyedContainer()
        this = try c.decode(BlendRange.self)
        underlying = try c.decode(BlendRange.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(this)
        try c.encode(underlying)
    }
}

/// A layer's Blend If settings. `ranges[0]` is the "Gray" entry (composite of the colour channels),
/// then one entry per colour channel of the document's mode (R, G, B / C, M, Y, K / L, a, b / Gray).
/// Empty = every pixel blends.
public struct BlendIf: Hashable, Sendable, Codable {
    public var ranges: [BlendRangePair]

    public init(ranges: [BlendRangePair] = []) { self.ranges = ranges }

    /// Whether no range hides anything (the Photoshop default).
    public var isDefault: Bool { ranges.allSatisfy(\.isFull) }

    /// Entry `i` (0 = Gray), full when not stored.
    public func get(_ i: Int) -> BlendRangePair { i >= 0 && i < ranges.count ? ranges[i] : .full }

    /// Set entry `i` (0 = Gray), growing the list with full ranges as needed. Trailing full entries
    /// are dropped so an all-default setting compares equal to `BlendIf()`.
    public mutating func set(_ i: Int, _ pair: BlendRangePair) {
        guard i >= 0 else { return }
        if ranges.count <= i { ranges.append(contentsOf: Array(repeating: .full, count: i + 1 - ranges.count)) }
        ranges[i] = pair
        while let last = ranges.last, last.isFull { ranges.removeLast() }
    }
}
