// Port of photocraft-algo's use of Rust `std::f32::consts` and `f32::to_radians` (crates/algo/src), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Rust's f32 constants are the nearest floats; Swift's `Float.pi` rounds toward zero (one ulp
// below). Every port uses these so angles and noise phases match photocraft bit for bit.

enum PCAMath {
    /// Rust `std::f32::consts::PI`.
    static let pi: Float = 3.14159265358979323846
    /// Rust `std::f32::consts::TAU`.
    static let tau: Float = 6.28318530717958647692
    /// Rust `std::f32::consts::FRAC_PI_2`.
    static let halfPi: Float = 1.57079632679489661923

    /// Rust `f32::to_radians`: `deg * (PI / 180)`.
    @inline(__always) static func radians(_ deg: Float) -> Float { deg * (pi / 180) }

    /// Rust's `f32 as i32`: saturating, NaN → 0 (Swift's `Int32(_:)` traps instead).
    @inline(__always) static func i32(_ v: Float) -> Int32 {
        if v.isNaN { return 0 }
        if v >= 2_147_483_648 { return .max }
        if v <= -2_147_483_648 { return .min }
        return Int32(v)
    }

    /// Rust's `f32 as usize` (saturating; NaN and negatives → 0), capped at 2^40 to stay usable.
    @inline(__always) static func usize(_ v: Float) -> Int {
        if !(v > 0) { return 0 }
        return v >= 1.0995116e12 ? 1 << 40 : Int(v)
    }

    /// Rust's `f32::max(self, 0)`: NaN → 0.
    @inline(__always) static func pos(_ v: Float) -> Float { Float.maximum(v, 0) }

    /// Rust's saturating `f32 as i32` (NaN → 0), kept within ±1e9 so neighbour taps cannot overflow.
    @inline(__always) static func floorToInt(_ v: Float) -> Int32 {
        if v.isNaN { return 0 }
        return Int32(min(max(v, -1e9), 1e9))
    }
}
