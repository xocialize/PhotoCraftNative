// BLAKE3 (unkeyed hash mode), the content address photocraft uses for `.pcraft` tiles and blobs
// and for smart-object identities (photocraft-io `smart_map::uuid_from`, `psd_export`'s
// `contents_uuid`; photocraft-format `store.rs`). Written from the BLAKE3 specification
// (O'Connor, Aumasson, Neves, Wilcox-O'Hearn, 2020; the reference implementation is CC0/Apache-2.0):
// CryptoKit has no BLAKE3. Replaces the `blake3` crate (`pure` feature) photocraft links,
// MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation

public struct BLAKE3: Sendable {
    typealias Words8 = SIMD8<UInt32>
    typealias Words16 = SIMD16<UInt32>

    static let iv = Words8(0x6A09_E667, 0xBB67_AE85, 0x3C6E_F372, 0xA54F_F53A, 0x510E_527F, 0x9B05_688C, 0x1F83_D9AB, 0x5BE0_CD19)
    static let chunkStart: UInt32 = 1, chunkEnd: UInt32 = 2, parent: UInt32 = 4, root: UInt32 = 8
    static let blockLen = 64, chunkLen = 1024

    /// The compression function with every word in a local (fast at -Onone too); the message
    /// schedule of the seven rounds is unrolled from the permutation.
    @inline(__always) static func compress(_ cv: Words8, _ block: Words16, _ counter: UInt64, _ blockLen: UInt32, _ flags: UInt32) -> Words16 {
        let m0 = block[0], m1 = block[1], m2 = block[2], m3 = block[3], m4 = block[4], m5 = block[5], m6 = block[6], m7 = block[7]
        let m8 = block[8], m9 = block[9], m10 = block[10], m11 = block[11], m12 = block[12], m13 = block[13], m14 = block[14], m15 = block[15]
        var v0 = cv[0], v1 = cv[1], v2 = cv[2], v3 = cv[3], v4 = cv[4], v5 = cv[5], v6 = cv[6], v7 = cv[7]
        var v8 = iv[0], v9 = iv[1], v10 = iv[2], v11 = iv[3]
        var v12 = UInt32(truncatingIfNeeded: counter), v13 = UInt32(truncatingIfNeeded: counter >> 32), v14 = blockLen, v15 = flags
        @inline(__always) func g(_ a: inout UInt32, _ b: inout UInt32, _ c: inout UInt32, _ d: inout UInt32, _ x: UInt32, _ y: UInt32) {
            a = a &+ b &+ x; d = (d ^ a) >> 16 | (d ^ a) << 16
            c = c &+ d; b = (b ^ c) >> 12 | (b ^ c) << 20
            a = a &+ b &+ y; d = (d ^ a) >> 8 | (d ^ a) << 24
            c = c &+ d; b = (b ^ c) >> 7 | (b ^ c) << 25
        }
        // Round 1.
        g(&v0, &v4, &v8, &v12, m0, m1); g(&v1, &v5, &v9, &v13, m2, m3)
        g(&v2, &v6, &v10, &v14, m4, m5); g(&v3, &v7, &v11, &v15, m6, m7)
        g(&v0, &v5, &v10, &v15, m8, m9); g(&v1, &v6, &v11, &v12, m10, m11)
        g(&v2, &v7, &v8, &v13, m12, m13); g(&v3, &v4, &v9, &v14, m14, m15)
        // Round 2.
        g(&v0, &v4, &v8, &v12, m2, m6); g(&v1, &v5, &v9, &v13, m3, m10)
        g(&v2, &v6, &v10, &v14, m7, m0); g(&v3, &v7, &v11, &v15, m4, m13)
        g(&v0, &v5, &v10, &v15, m1, m11); g(&v1, &v6, &v11, &v12, m12, m5)
        g(&v2, &v7, &v8, &v13, m9, m14); g(&v3, &v4, &v9, &v14, m15, m8)
        // Round 3.
        g(&v0, &v4, &v8, &v12, m3, m4); g(&v1, &v5, &v9, &v13, m10, m12)
        g(&v2, &v6, &v10, &v14, m13, m2); g(&v3, &v7, &v11, &v15, m7, m14)
        g(&v0, &v5, &v10, &v15, m6, m5); g(&v1, &v6, &v11, &v12, m9, m0)
        g(&v2, &v7, &v8, &v13, m11, m15); g(&v3, &v4, &v9, &v14, m8, m1)
        // Round 4.
        g(&v0, &v4, &v8, &v12, m10, m7); g(&v1, &v5, &v9, &v13, m12, m9)
        g(&v2, &v6, &v10, &v14, m14, m3); g(&v3, &v7, &v11, &v15, m13, m15)
        g(&v0, &v5, &v10, &v15, m4, m0); g(&v1, &v6, &v11, &v12, m11, m2)
        g(&v2, &v7, &v8, &v13, m5, m8); g(&v3, &v4, &v9, &v14, m1, m6)
        // Round 5.
        g(&v0, &v4, &v8, &v12, m12, m13); g(&v1, &v5, &v9, &v13, m9, m11)
        g(&v2, &v6, &v10, &v14, m15, m10); g(&v3, &v7, &v11, &v15, m14, m8)
        g(&v0, &v5, &v10, &v15, m7, m2); g(&v1, &v6, &v11, &v12, m5, m3)
        g(&v2, &v7, &v8, &v13, m0, m1); g(&v3, &v4, &v9, &v14, m6, m4)
        // Round 6.
        g(&v0, &v4, &v8, &v12, m9, m14); g(&v1, &v5, &v9, &v13, m11, m5)
        g(&v2, &v6, &v10, &v14, m8, m12); g(&v3, &v7, &v11, &v15, m15, m1)
        g(&v0, &v5, &v10, &v15, m13, m3); g(&v1, &v6, &v11, &v12, m0, m10)
        g(&v2, &v7, &v8, &v13, m2, m6); g(&v3, &v4, &v9, &v14, m4, m7)
        // Round 7.
        g(&v0, &v4, &v8, &v12, m11, m15); g(&v1, &v5, &v9, &v13, m5, m0)
        g(&v2, &v6, &v10, &v14, m1, m9); g(&v3, &v7, &v11, &v15, m8, m6)
        g(&v0, &v5, &v10, &v15, m14, m10); g(&v1, &v6, &v11, &v12, m2, m12)
        g(&v2, &v7, &v8, &v13, m3, m4); g(&v3, &v4, &v9, &v14, m7, m13)
        return Words16(v0 ^ v8, v1 ^ v9, v2 ^ v10, v3 ^ v11, v4 ^ v12, v5 ^ v13, v6 ^ v14, v7 ^ v15,
                       v8 ^ cv[0], v9 ^ cv[1], v10 ^ cv[2], v11 ^ cv[3], v12 ^ cv[4], v13 ^ cv[5], v14 ^ cv[6], v15 ^ cv[7])
    }

    /// Little-endian words of up to 64 bytes at `p` (zero-padded).
    @inline(__always) static func words(_ p: UnsafeRawBufferPointer, _ at: Int, _ n: Int) -> Words16 {
        var w = Words16()
        if n == 64 {
            // Apple platforms are little-endian: one unaligned vector load.
            return p.loadUnaligned(fromByteOffset: at, as: Words16.self)
        }
        for i in 0 ..< n { w[i >> 2] |= UInt32(p[at + i]) << (8 * UInt32(i & 3)) }
        return w
    }

    struct Output {
        var cv: Words8
        var block: Words16
        var counter: UInt64
        var blockLen: UInt32
        var flags: UInt32

        var chainingValue: Words8 { BLAKE3.compress(cv, block, counter, blockLen, flags).lowHalf }

        func rootBytes(_ n: Int) -> [UInt8] {
            var out: [UInt8] = []
            out.reserveCapacity(n)
            var c: UInt64 = 0
            while out.count < n {
                let w = BLAKE3.compress(cv, block, c, blockLen, flags | BLAKE3.root)
                for i in 0 ..< 16 {
                    for k in 0 ..< 4 where out.count < n { out.append(UInt8(truncatingIfNeeded: w[i] >> (8 * UInt32(k)))) }
                }
                c += 1
            }
            return out
        }
    }

    struct ChunkState {
        var cv: Words8
        var counter: UInt64
        var block = Words16()
        var blockFill = 0
        var blocksCompressed = 0

        init(_ key: Words8, _ counter: UInt64) { cv = key; self.counter = counter }

        var length: Int { BLAKE3.blockLen * blocksCompressed + blockFill }
        var startFlag: UInt32 { blocksCompressed == 0 ? BLAKE3.chunkStart : 0 }

        /// Absorbs `n` bytes at `p[at...]` (never more than the chunk holds).
        mutating func update(_ p: UnsafeRawBufferPointer, _ at: Int, _ n: Int) {
            var at = at, n = n
            while n > 0 {
                if blockFill == BLAKE3.blockLen {
                    cv = BLAKE3.compress(cv, block, counter, UInt32(BLAKE3.blockLen), startFlag).lowHalf
                    blocksCompressed += 1
                    block = Words16()
                    blockFill = 0
                }
                if blockFill == 0, n > BLAKE3.blockLen {
                    // A whole block with more input after it: compress straight from the input.
                    block = BLAKE3.words(p, at, 64)
                    blockFill = 64
                    at += 64
                    n -= 64
                    continue
                }
                let take = min(BLAKE3.blockLen - blockFill, n)
                for i in 0 ..< take {
                    let k = blockFill + i
                    block[k >> 2] |= UInt32(p[at + i]) << (8 * UInt32(k & 3))
                }
                blockFill += take
                at += take
                n -= take
            }
        }

        var output: Output {
            Output(cv: cv, block: block, counter: counter, blockLen: UInt32(blockFill), flags: startFlag | BLAKE3.chunkEnd)
        }
    }

    static func parentOutput(_ left: Words8, _ right: Words8) -> Output {
        Output(cv: iv, block: Words16(lowHalf: left, highHalf: right), counter: 0, blockLen: UInt32(blockLen), flags: parent)
    }

    private var chunk = ChunkState(BLAKE3.iv, 0)
    private var stack: [Words8] = []

    public init() {}

    /// Absorbs more input.
    public mutating func update(_ data: [UInt8]) {
        data.withUnsafeBytes { p in
            var at = 0
            while at < p.count {
                if chunk.length == BLAKE3.chunkLen {
                    var cv = chunk.output.chainingValue
                    var total = chunk.counter + 1
                    while total & 1 == 0, let left = stack.popLast() {
                        cv = BLAKE3.parentOutput(left, cv).chainingValue
                        total >>= 1
                    }
                    stack.append(cv)
                    chunk = ChunkState(BLAKE3.iv, chunk.counter + 1)
                }
                let take = min(BLAKE3.chunkLen - chunk.length, p.count - at)
                chunk.update(p, at, take)
                at += take
            }
        }
    }

    /// The hash (32 bytes by default; BLAKE3 is an XOF).
    public func finalize(count: Int = 32) -> [UInt8] {
        var out = chunk.output
        var i = stack.count
        while i > 0 {
            i -= 1
            out = BLAKE3.parentOutput(stack[i], out.chainingValue)
        }
        return out.rootBytes(count)
    }

    /// One-shot hash.
    public static func hash(_ data: [UInt8]) -> [UInt8] {
        var h = BLAKE3()
        h.update(data)
        return h.finalize()
    }

    /// Lower-case hex of `hash(data)`.
    public static func hex(_ data: [UInt8]) -> String { hash(data).map { String(format: "%02x", $0) }.joined() }
}
