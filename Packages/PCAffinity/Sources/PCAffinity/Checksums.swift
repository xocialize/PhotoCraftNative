// Port of photocraft-affinity (crates/affinity/src/container.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
// The checksums photocraft takes from crates, in Swift: CRC-32 (IEEE, as `crc32fast`; archive
// entries and PNG chunks), Adler-32 (the zlib trailer `flate2` verifies) and XXH64 (the zstd content
// checksum).

package enum Checksum {
    // MARK: CRC-32 (reflected, polynomial 0xEDB88320), slice-by-8.

    /// Eight 256-entry tables, flattened: table k at `k * 256`.
    private static let crcTable: [UInt32] = {
        var t = [UInt32](repeating: 0, count: 8 * 256)
        for i in 0..<256 {
            var c = UInt32(i)
            for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
            t[i] = c
        }
        for k in 1..<8 {
            for i in 0..<256 {
                let prev = t[(k - 1) * 256 + i]
                t[k * 256 + i] = (prev >> 8) ^ t[Int(prev & 0xFF)]
            }
        }
        return t
    }()

    package static func crc32(_ bytes: [UInt8]) -> UInt32 {
        bytes.withUnsafeBufferPointer { crc32($0) }
    }

    package static func crc32(_ bytes: ArraySlice<UInt8>) -> UInt32 {
        bytes.withUnsafeBufferPointer { crc32($0) }
    }

    package static func crc32(_ p: UnsafeBufferPointer<UInt8>) -> UInt32 {
        crcTable.withUnsafeBufferPointer { t in
            var crc: UInt32 = 0xFFFF_FFFF
            var i = 0
            let n = p.count
            while n - i >= 8 {
                let one = (UInt32(p[i]) | UInt32(p[i + 1]) << 8 | UInt32(p[i + 2]) << 16 | UInt32(p[i + 3]) << 24) ^ crc
                let two = UInt32(p[i + 4]) | UInt32(p[i + 5]) << 8 | UInt32(p[i + 6]) << 16 | UInt32(p[i + 7]) << 24
                crc = t[7 * 256 + Int(one & 0xFF)] ^ t[6 * 256 + Int((one >> 8) & 0xFF)]
                    ^ t[5 * 256 + Int((one >> 16) & 0xFF)] ^ t[4 * 256 + Int(one >> 24)]
                    ^ t[3 * 256 + Int(two & 0xFF)] ^ t[2 * 256 + Int((two >> 8) & 0xFF)]
                    ^ t[1 * 256 + Int((two >> 16) & 0xFF)] ^ t[Int(two >> 24)]
                i += 8
            }
            while i < n {
                crc = t[Int((crc ^ UInt32(p[i])) & 0xFF)] ^ (crc >> 8)
                i += 1
            }
            return ~crc
        }
    }

    // MARK: Adler-32

    package static func adler32(_ bytes: [UInt8]) -> UInt32 {
        bytes.withUnsafeBufferPointer { p in
            var a: UInt32 = 1
            var b: UInt32 = 0
            var i = 0
            while i < p.count {
                // 5552 is the most bytes before `b` can overflow 32 bits.
                let end = min(p.count, i + 5552)
                while i < end {
                    a &+= UInt32(p[i])
                    b &+= a
                    i += 1
                }
                a %= 65521
                b %= 65521
            }
            return b << 16 | a
        }
    }

    // MARK: XXH64 (seed 0 unless given)

    private static let p1: UInt64 = 11_400_714_785_074_694_791
    private static let p2: UInt64 = 14_029_467_366_897_019_727
    private static let p3: UInt64 = 1_609_587_929_392_839_161
    private static let p4: UInt64 = 9_650_029_242_287_828_579
    private static let p5: UInt64 = 2_870_177_450_012_600_261

    @inline(__always) private static func rotl(_ x: UInt64, _ r: UInt64) -> UInt64 { (x << r) | (x >> (64 - r)) }

    @inline(__always) private static func round(_ acc: UInt64, _ input: UInt64) -> UInt64 {
        rotl(acc &+ input &* p2, 31) &* p1
    }

    @inline(__always) private static func merge(_ acc: UInt64, _ val: UInt64) -> UInt64 {
        (acc ^ round(0, val)) &* p1 &+ p4
    }

    package static func xxh64(_ bytes: ArraySlice<UInt8>, seed: UInt64 = 0) -> UInt64 {
        bytes.withUnsafeBufferPointer { xxh64($0, seed: seed) }
    }

    package static func xxh64(_ p: UnsafeBufferPointer<UInt8>, seed: UInt64 = 0) -> UInt64 {
        @inline(__always) func le64(_ i: Int) -> UInt64 {
            var v: UInt64 = 0
            for k in 0..<8 { v |= UInt64(p[i + k]) << (8 * UInt64(k)) }
            return v
        }
        @inline(__always) func le32(_ i: Int) -> UInt64 {
            UInt64(p[i]) | UInt64(p[i + 1]) << 8 | UInt64(p[i + 2]) << 16 | UInt64(p[i + 3]) << 24
        }
        let n = p.count
        var i = 0
        var h: UInt64
        if n >= 32 {
            var v1 = seed &+ p1 &+ p2
            var v2 = seed &+ p2
            var v3 = seed
            var v4 = seed &- p1
            while n - i >= 32 {
                v1 = round(v1, le64(i))
                v2 = round(v2, le64(i + 8))
                v3 = round(v3, le64(i + 16))
                v4 = round(v4, le64(i + 24))
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
        h &+= UInt64(n)
        while n - i >= 8 {
            h ^= round(0, le64(i))
            h = rotl(h, 27) &* p1 &+ p4
            i += 8
        }
        if n - i >= 4 {
            h ^= le32(i) &* p1
            h = rotl(h, 23) &* p2 &+ p3
            i += 4
        }
        while i < n {
            h ^= UInt64(p[i]) &* p5
            h = rotl(h, 11) &* p1
            i += 1
        }
        h ^= h >> 33
        h &*= p2
        h ^= h >> 29
        h &*= p3
        h ^= h >> 32
        return h
    }
}
