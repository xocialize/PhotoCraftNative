// XXH64 (seed 0), the content checksum of zstd frames (RFC 8878 §3.1.1: the low 32 bits).
// Port support for photocraft-format (crates/format/src/store.rs, through ruzstd's `hash`
// feature), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors. Written from the
// xxHash specification (Yann Collet, BSD-2-Clause).

enum XXH64 {
    static let p1: UInt64 = 0x9E37_79B1_85EB_CA87
    static let p2: UInt64 = 0xC2B2_AE3D_27D4_EB4F
    static let p3: UInt64 = 0x1656_67B1_9E37_79F9
    static let p4: UInt64 = 0x85EB_CA77_C2B2_AE63
    static let p5: UInt64 = 0x27D4_EB2F_1656_67C5

    @inline(__always) static func rotl(_ x: UInt64, _ r: UInt64) -> UInt64 { (x &<< r) | (x &>> (64 &- r)) }

    @inline(__always) static func round(_ acc: UInt64, _ input: UInt64) -> UInt64 {
        rotl(acc &+ input &* p2, 31) &* p1
    }

    @inline(__always) static func merge(_ acc: UInt64, _ val: UInt64) -> UInt64 {
        (acc ^ round(0, val)) &* p1 &+ p4
    }

    /// XXH64 of `len` bytes at `p`.
    static func hash(_ p: UnsafeRawPointer, _ len: Int, seed: UInt64 = 0) -> UInt64 {
        @inline(__always) func r64(_ i: Int) -> UInt64 { UInt64(littleEndian: p.loadUnaligned(fromByteOffset: i, as: UInt64.self)) }
        @inline(__always) func r32(_ i: Int) -> UInt64 { UInt64(UInt32(littleEndian: p.loadUnaligned(fromByteOffset: i, as: UInt32.self))) }
        var i = 0
        var h: UInt64
        if len >= 32 {
            var v1 = seed &+ p1 &+ p2, v2 = seed &+ p2, v3 = seed, v4 = seed &- p1
            while i + 32 <= len {
                v1 = round(v1, r64(i))
                v2 = round(v2, r64(i + 8))
                v3 = round(v3, r64(i + 16))
                v4 = round(v4, r64(i + 24))
                i += 32
            }
            h = rotl(v1, 1) &+ rotl(v2, 7) &+ rotl(v3, 12) &+ rotl(v4, 18)
            h = merge(h, v1)
            h = merge(h, v2)
            h = merge(h, v3)
            h = merge(h, v4)
        } else {
            h = seed &+ p5
        }
        h = h &+ UInt64(len)
        while i + 8 <= len {
            h ^= round(0, r64(i))
            h = rotl(h, 27) &* p1 &+ p4
            i += 8
        }
        if i + 4 <= len {
            h ^= r32(i) &* p1
            h = rotl(h, 23) &* p2 &+ p3
            i += 4
        }
        while i < len {
            h ^= UInt64(p.load(fromByteOffset: i, as: UInt8.self)) &* p5
            h = rotl(h, 11) &* p1
            i += 1
        }
        h ^= h &>> 33
        h = h &* p2
        h ^= h &>> 29
        h = h &* p3
        h ^= h &>> 32
        return h
    }

    static func hash(_ bytes: [UInt8], seed: UInt64 = 0) -> UInt64 {
        withUnsafeBytes(of: UInt64(0)) { zero in
            bytes.withUnsafeBytes { b in
                // An empty array may have no storage; any valid pointer serves for zero bytes.
                guard let base = b.baseAddress ?? zero.baseAddress else { return 0 }
                return hash(base, b.count, seed: seed)
            }
        }
    }
}
