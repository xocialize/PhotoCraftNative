// Geometry the document model needs beyond PCFoundation: f64 points, 2D affine transforms and
// overflow-safe rectangle helpers.
// Port of photocraft-geom (crates/geom/src/lib.rs), MIT OR Apache-2.0, © ArtCraft Team and the
// PhotoCraft contributors. PixelRect/PixelSize/TileCoord live in PCFoundation; maths bridges to
// simd and CoreGraphics.

import CoreGraphics
import PCFoundation
import simd

/// A point in document space (f64, y down) — photocraft `Point`. JSON: `{"x":…,"y":…}`.
public struct PCPoint: Hashable, Sendable, Codable, CustomStringConvertible {
    public var x: Double
    public var y: Double

    public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
    public init(x: Double, y: Double) { self.x = x; self.y = y }
    public init(_ v: SIMD2<Double>) { x = v.x; y = v.y }
    public init(_ p: CGPoint) { x = Double(p.x); y = Double(p.y) }

    public static let zero = PCPoint(0, 0)

    public var simd: SIMD2<Double> { SIMD2(x, y) }
    public var cgPoint: CGPoint { CGPoint(x: x, y: y) }
    public var description: String { "(\(x), \(y))" }
}

/// 2D affine transform `[a c e; b d f; 0 0 1]` on column vectors — photocraft `Affine`, stored as
/// `m = [a, b, c, d, e, f]` (the same order as `CGAffineTransform(a:b:c:d:tx:ty:)`).
/// JSON: `{"m":[a,b,c,d,e,f]}`.
public struct PCAffine: Hashable, Sendable, Codable, CustomStringConvertible {
    public var a: Double, b: Double, c: Double, d: Double, e: Double, f: Double

    public init(a: Double, b: Double, c: Double, d: Double, e: Double, f: Double) {
        self.a = a; self.b = b; self.c = c; self.d = d; self.e = e; self.f = f
    }

    /// From photocraft's `m` array; missing entries take the identity's.
    public init(m: [Double]) {
        let id: [Double] = [1, 0, 0, 1, 0, 0]
        func at(_ i: Int) -> Double { i < m.count ? m[i] : id[i] }
        self.init(a: at(0), b: at(1), c: at(2), d: at(3), e: at(4), f: at(5))
    }

    public init(_ t: CGAffineTransform) {
        self.init(a: Double(t.a), b: Double(t.b), c: Double(t.c), d: Double(t.d), e: Double(t.tx), f: Double(t.ty))
    }

    public static let identity = PCAffine(a: 1, b: 0, c: 0, d: 1, e: 0, f: 0)

    public var m: [Double] {
        get { [a, b, c, d, e, f] }
        set { self = PCAffine(m: newValue) }
    }

    public var cgAffineTransform: CGAffineTransform { CGAffineTransform(a: a, b: b, c: c, d: d, tx: e, ty: f) }

    /// The linear part and translation as a simd matrix (columns `(a, b)`, `(c, d)`, `(e, f)`).
    public var simd: simd_double3x2 { simd_double3x2(SIMD2(a, b), SIMD2(c, d), SIMD2(e, f)) }

    public static func translate(_ dx: Double, _ dy: Double) -> PCAffine { PCAffine(a: 1, b: 0, c: 0, d: 1, e: dx, f: dy) }
    public static func scale(_ s: Double) -> PCAffine { PCAffine(a: s, b: 0, c: 0, d: s, e: 0, f: 0) }
    public static func scale(_ sx: Double, _ sy: Double) -> PCAffine { PCAffine(a: sx, b: 0, c: 0, d: sy, e: 0, f: 0) }
    public static func rotate(_ radians: Double) -> PCAffine {
        let (s, c) = (sin(radians), cos(radians))
        return PCAffine(a: c, b: s, c: -s, d: c, e: 0, f: 0)
    }

    /// `self` applied first, then `other` (photocraft `then`).
    public func then(_ other: PCAffine) -> PCAffine { other.mul(self) }

    /// `self · o`: `o` applied first, then `self`.
    public func mul(_ o: PCAffine) -> PCAffine {
        PCAffine(a: a * o.a + c * o.b, b: b * o.a + d * o.b,
                 c: a * o.c + c * o.d, d: b * o.c + d * o.d,
                 e: a * o.e + c * o.f + e, f: b * o.e + d * o.f + f)
    }

    public func apply(_ p: PCPoint) -> PCPoint { PCPoint(a * p.x + c * p.y + e, b * p.x + d * p.y + f) }
    public func apply(_ p: SIMD2<Double>) -> SIMD2<Double> { SIMD2(a * p.x + c * p.y + e, b * p.x + d * p.y + f) }

    public var determinant: Double { a * d - b * c }

    /// The inverse, or nil for a (near-)singular transform.
    public var inverse: PCAffine? {
        let det = determinant
        if abs(det) < 1e-12 { return nil }
        let inv = 1 / det
        return PCAffine(a: d * inv, b: -b * inv, c: -c * inv, d: a * inv, e: (c * f - d * e) * inv, f: (b * e - a * f) * inv)
    }

    public var isIdentity: Bool { self == .identity }
    public var description: String { "[\(a), \(b), \(c), \(d), \(e), \(f)]" }

    enum CodingKeys: String, CodingKey { case m }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(m: try c.decodeFixed([Double].self, forKey: .m, count: 6))
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(m, forKey: .m)
    }
}

// MARK: - Overflow-safe rectangle helpers (photocraft-geom `Rect`)

extension PixelRect {
    /// photocraft `Rect::from_xywh`: saturating at Int32's range.
    public static func xywh(_ x: Int32, _ y: Int32, _ w: Int, _ h: Int) -> PixelRect {
        PixelRect(x0: x, y0: y, x1: Int32(clamping: Int(x) + w), y1: Int32(clamping: Int(y) + h))
    }

    /// photocraft `Rect::from_size`: `(0, 0)–(w, h)`, saturating.
    public init(size: PixelSize) {
        self.init(x0: 0, y0: 0, x1: Int32(clamping: max(0, size.width)), y1: Int32(clamping: max(0, size.height)))
    }

    /// photocraft `Rect::translate`: moved by (dx, dy), saturating instead of trapping.
    public func translated(dx: Int32, dy: Int32) -> PixelRect {
        PixelRect(x0: x0.addingSaturating(dx), y0: y0.addingSaturating(dy), x1: x1.addingSaturating(dx), y1: y1.addingSaturating(dy))
    }

    /// photocraft `Rect::inflate`: grown by `d` on every side, saturating.
    public func inflated(by d: Int32) -> PixelRect {
        PixelRect(x0: x0.addingSaturating(-d), y0: y0.addingSaturating(-d), x1: x1.addingSaturating(d), y1: y1.addingSaturating(d))
    }

    public var size: PixelSize { PixelSize(width: width, height: height) }
}

extension Int32 {
    func addingSaturating(_ o: Int32) -> Int32 {
        let (r, overflow) = addingReportingOverflow(o)
        if !overflow { return r }
        return o > 0 ? .max : .min
    }
}

extension PixelSize {
    /// Pixel count (never overflows for any stored size).
    public var area: Int { max(0, width).multipliedReportingOverflow(by: max(0, height)).overflow ? .max : max(0, width) * max(0, height) }
    public var isEmpty: Bool { width <= 0 || height <= 0 }
}
