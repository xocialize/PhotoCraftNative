// Port of photocraft-affinity (crates/affinity/src/lib.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
// Reader for native Affinity documents (`.af`, and `.afdesign`/`.afphoto`/`.afpub` from Affinity 1
// and 2): the archive container, the tagged object stream in `doc.dat`, and the subset of the
// document model PhotoCraft imports.
//
// Layouts follow the MIT-licensed afread reference and were checked by photocraft against public
// documents saved by Affinity 1.x to 3.x (container versions 8 to 12); see photocraft's crate README
// for provenance and the exact supported subset. Nothing here writes Affinity files.
//
// Everything is bounded: the input is attacker-facing, so every length, count, offset, nesting
// depth and decompressed size is checked before it is used, and malformed input throws
// `AffinityError` instead of trapping.

/// Namespace for the reader. Entry points: `Affinity.read(_:limits:)` (the document model),
/// `Affinity.preview(_:)` (the embedded PNG thumbnail), `Affinity.Archive` (container entries) and
/// `Affinity.Stream.parse(_:)` (the raw object stream).
public enum Affinity {}

/// Why a file could not be read. Messages are short reasons; callers add advice.
public enum AffinityError: Error, Hashable, Sendable, CustomStringConvertible {
    case malformed(String)
    case unsupported(String)
    case limit(String)

    public var description: String {
        switch self {
        case .malformed(let s): "damaged Affinity file: \(s)"
        case .unsupported(let s): "unsupported Affinity file: \(s)"
        case .limit(let s): "Affinity file exceeds a safety limit: \(s)"
        }
    }
}

// MARK: - Shared numeric helpers (Rust `as`/`try_from` semantics without traps)

extension Affinity {
    /// Rust's saturating `f64 as` integer cast: NaN becomes 0, out-of-range values clamp.
    @inline(__always)
    static func saturating<T: FixedWidthInteger>(_ v: Double) -> T {
        if v.isNaN { return 0 }
        if v <= Double(T.min) { return T.min }
        if v >= Double(T.max) { return T.max }
        return T(v)
    }

    /// Rust's `f64::clamp`: NaN passes through as NaN.
    @inline(__always)
    static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
        if v < lo { return lo }
        if v > hi { return hi }
        return v
    }

    /// Rust's `f64::rem_euclid`.
    @inline(__always)
    static func remEuclid(_ v: Double, _ m: Double) -> Double {
        let r = v.truncatingRemainder(dividingBy: m)
        return r < 0 ? r + abs(m) : r
    }

    /// Rust's `String::from_utf8_lossy`.
    @inline(__always)
    static func lossy<C: Collection>(_ bytes: C) -> String where C.Element == UInt8 {
        String(decoding: bytes, as: UTF8.self)
    }
}
