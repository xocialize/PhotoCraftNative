// Port of photocraft-paint (crates/paint/src/lib.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Rust numeric semantics the port depends on, spelled out once: `f32::clamp` (NaN passes through),
// `f32::min`/`max` (a NaN operand is ignored), saturating float → integer `as` casts (NaN → 0),
// `rem_euclid`, and the integer saturating add/sub used for dab rectangles. Swift's own
// conversions trap on NaN or overflow, so every cast a hostile brush value can reach goes
// through these.

import Foundation
import PCFoundation

/// A document position (photocraft-geom `Point`): f64, y down.
public struct PaintPoint: Hashable, Sendable, Codable, CustomStringConvertible {
    public var x: Double
    public var y: Double
    public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
    public init(x: Double, y: Double) { self.x = x; self.y = y }
    public var description: String { "(\(x), \(y))" }
}

// MARK: Float semantics

/// Rust `f32::clamp`: NaN stays NaN.
@inline(__always) @usableFromInline func clampR(_ v: Float, _ lo: Float, _ hi: Float) -> Float {
    var x = v
    if x < lo { x = lo }
    if x > hi { x = hi }
    return x
}

@inline(__always) @usableFromInline func clampR(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
    var x = v
    if x < lo { x = lo }
    if x > hi { x = hi }
    return x
}

/// Rust `f32::min`: the other operand when one is NaN (IEEE minNum).
@inline(__always) @usableFromInline func minR(_ a: Float, _ b: Float) -> Float { Float.minimum(a, b) }
@inline(__always) @usableFromInline func maxR(_ a: Float, _ b: Float) -> Float { Float.maximum(a, b) }
@inline(__always) @usableFromInline func minR(_ a: Double, _ b: Double) -> Double { Double.minimum(a, b) }
@inline(__always) @usableFromInline func maxR(_ a: Double, _ b: Double) -> Double { Double.maximum(a, b) }

/// Rust `rem_euclid` for floats.
@inline(__always) @usableFromInline func remEuclid(_ a: Float, _ b: Float) -> Float {
    let r = a.truncatingRemainder(dividingBy: b)
    return r < 0 ? r + abs(b) : r
}

@inline(__always) @usableFromInline func remEuclid(_ a: Double, _ b: Double) -> Double {
    let r = a.truncatingRemainder(dividingBy: b)
    return r < 0 ? r + abs(b) : r
}

/// Rust `rem_euclid` for integers.
@inline(__always) @usableFromInline func remEuclid(_ a: Int, _ b: Int) -> Int {
    let r = a % b
    return r < 0 ? r + abs(b) : r
}

@inline(__always) @usableFromInline func remEuclid(_ a: Int32, _ b: Int32) -> Int32 {
    let r = a % b
    return r < 0 ? r + abs(b) : r
}

/// Rust `div_euclid` for i32.
@inline(__always) @usableFromInline func divEuclid(_ a: Int32, _ b: Int32) -> Int32 {
    let q = a / b
    return a % b < 0 ? (b > 0 ? q - 1 : q + 1) : q
}

/// `f32::to_radians` / `to_degrees` with Rust's constants.
@usableFromInline let radiansPerDegree: Float = Float.pi / 180
@usableFromInline let degreesPerRadian: Float = 57.2957795130823208767981548141051703

@inline(__always) @usableFromInline func toRadians(_ d: Float) -> Float { d * radiansPerDegree }
@inline(__always) @usableFromInline func toDegrees(_ r: Float) -> Float { r * degreesPerRadian }
@inline(__always) @usableFromInline func toRadians(_ d: Double) -> Double { d * (Double.pi / 180) }

// MARK: Saturating casts (Rust `as`)

@inline(__always) @usableFromInline func asI32(_ v: Float) -> Int32 {
    if v.isNaN { return 0 }
    if v >= 2147483648.0 { return .max }
    if v <= -2147483648.0 { return .min }
    return Int32(v)
}

@inline(__always) @usableFromInline func asI32(_ v: Double) -> Int32 {
    if v.isNaN { return 0 }
    if v >= 2147483647.0 { return .max }
    if v <= -2147483648.0 { return .min }
    return Int32(v)
}

@inline(__always) @usableFromInline func asI64(_ v: Float) -> Int64 {
    if v.isNaN { return 0 }
    if v >= 9.223372e18 { return .max }
    if v <= -9.223372e18 { return .min }
    return Int64(v)
}

@inline(__always) @usableFromInline func asI64(_ v: Double) -> Int64 {
    if v.isNaN { return 0 }
    if v >= 9.2233720368547758e18 { return .max }
    if v <= -9.2233720368547758e18 { return .min }
    return Int64(v)
}

@inline(__always) @usableFromInline func asU32(_ v: Float) -> UInt32 {
    if v.isNaN || v <= 0 { return 0 }
    if v >= 4294967296.0 { return .max }
    return UInt32(v)
}

@inline(__always) @usableFromInline func asU64(_ v: Double) -> UInt64 {
    if v.isNaN || v <= 0 { return 0 }
    if v >= 18446744073709551616.0 { return .max }
    return UInt64(v)
}

/// `as usize`.
@inline(__always) @usableFromInline func asUsize(_ v: Float) -> Int {
    if v.isNaN || v <= 0 { return 0 }
    if v >= 9.223372e18 { return .max }
    return Int(v)
}

@inline(__always) @usableFromInline func asUsize(_ v: Double) -> Int {
    if v.isNaN || v <= 0 { return 0 }
    if v >= 9.2233720368547758e18 { return .max }
    return Int(v)
}

/// `as u16` (quantising a tip sample).
@inline(__always) @usableFromInline func asU16(_ v: Float) -> UInt16 {
    if v.isNaN || v <= 0 { return 0 }
    if v >= 65535 { return .max }
    return UInt16(v)
}

// MARK: Integer saturation

extension Int32 {
    @inline(__always) @usableFromInline func satAdd(_ o: Int32) -> Int32 {
        let (r, o1) = addingReportingOverflow(o)
        return o1 ? (o > 0 ? .max : .min) : r
    }
    @inline(__always) @usableFromInline func satSub(_ o: Int32) -> Int32 {
        let (r, o1) = subtractingReportingOverflow(o)
        return o1 ? (o > 0 ? .min : .max) : r
    }
}

// MARK: Pixel-rectangle helpers

extension PixelRect {
    /// photocraft `Rect::new`.
    @inline(__always) @usableFromInline init(_ x0: Int32, _ y0: Int32, _ x1: Int32, _ y1: Int32) {
        self.init(x0: x0, y0: y0, x1: x1, y1: y1)
    }

    /// `Rect::inflate` (saturating).
    func inflated(_ m: Int32) -> PixelRect {
        PixelRect(x0.satSub(m), y0.satSub(m), x1.satAdd(m), y1.satAdd(m))
    }

    /// `Rect::translate` (saturating).
    func translated(_ dx: Int32, _ dy: Int32) -> PixelRect {
        PixelRect(x0.satAdd(dx), y0.satAdd(dy), x1.satAdd(dx), y1.satAdd(dy))
    }
}
