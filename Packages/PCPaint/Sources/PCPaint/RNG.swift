// Port of photocraft-paint (crates/paint/src/rng.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Counter-based deterministic randomness. Every random value is a pure hash of
// `(seed, index, stream)`, so a dab's jitter depends only on the stroke seed and the dab's
// position in the stroke — never on how the points were chunked, on thread scheduling or on
// earlier draws. That is what makes journaled strokes replay exactly.

public enum PaintRNG {
    /// SplitMix64 finaliser.
    @inlinable public static func mix64(_ z0: UInt64) -> UInt64 {
        var z = z0 &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1).
    @inlinable public static func rand01(_ seed: UInt64, _ index: UInt64, _ stream: UInt64) -> Float {
        let h = mix64(seed ^ mix64((index &* 0xD1B5_4A32_D192_ED03) ^ (stream &* 0x8CB9_2BA7_2F3D_8DD7)))
        return Float(h >> 40) / Float(1 << 24)
    }

    /// Uniform in [-1, 1).
    @inlinable public static func randSigned(_ seed: UInt64, _ index: UInt64, _ stream: UInt64) -> Float {
        rand01(seed, index, stream) * 2 - 1
    }

    /// Hash of integer document coordinates to [0, 1) (noise, dissolve, dither).
    @inlinable public static func hash2(_ x: Int32, _ y: Int32, _ salt: UInt64) -> Float {
        let k = (UInt64(UInt32(bitPattern: x)) << 32) | UInt64(UInt32(bitPattern: y))
        return Float(mix64(k ^ (salt &* 0xA24B_AED4_963E_E407)) >> 40) / Float(1 << 24)
    }

    /// Seed derived from arbitrary bytes (FNV-1a then mixed), for commands without an explicit seed.
    public static func seed(fromBytes b: some Sequence<UInt8>) -> UInt64 {
        var h: UInt64 = 0xCBF2_9CE4_8422_2325
        for x in b {
            h ^= UInt64(x)
            h = h &* 0x0000_0100_0000_01B3
        }
        return mix64(h)
    }

    /// Streams: one per random quantity so they are independent.
    public enum Stream {
        public static let size: UInt64 = 1
        public static let angle: UInt64 = 2
        public static let roundness: UInt64 = 3
        public static let flipX: UInt64 = 4
        public static let flipY: UInt64 = 5
        public static let scatterX: UInt64 = 6
        public static let scatterY: UInt64 = 7
        public static let count: UInt64 = 8
        public static let opacity: UInt64 = 9
        public static let flow: UInt64 = 10
        public static let fgBg: UInt64 = 11
        public static let hue: UInt64 = 12
        public static let sat: UInt64 = 13
        public static let bright: UInt64 = 14
        public static let depth: UInt64 = 15
        public static let dualX: UInt64 = 16
        public static let dualY: UInt64 = 17
        public static let dualFlip: UInt64 = 18
        public static let wet: UInt64 = 19
        public static let mix: UInt64 = 20
    }
}
