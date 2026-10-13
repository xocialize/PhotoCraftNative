// A fast Zstandard compressor (RFC 8878) writing frames any conforming decoder reads (libzstd,
// ruzstd): single-pass LZ77 with one hash probe per position and repeat-offset checks (zstd's
// "fast" strategy), Huffman-coded literals (one or four streams, FSE-compressed or direct
// weights), RLE literals, sequences in predefined or RLE FSE modes, RLE and raw blocks for
// uniform or incompressible data, and the XXH64 content checksum.
// Port support for photocraft-format (crates/format/src/store.rs `compress`, which calls ruzstd's
// `compress_to_vec` at `CompressionLevel::Fastest`), MIT OR Apache-2.0, © ArtCraft Team and the
// PhotoCraft contributors. See `PcraftCodec` for why the format writes zstd here.

import Foundation

/// Bits written least-significant first into a buffer sized by the caller (zstd's backward
/// streams are read from the end).
struct ZstdBitWriter {
    private let buf: UnsafeMutablePointer<UInt8>
    private let capacity: Int
    private var pos = 0
    private var acc: UInt64 = 0
    private var count = 0

    /// A writer for at most `capacity` bytes.
    init(capacity: Int) {
        self.capacity = capacity + 8
        buf = .allocate(capacity: self.capacity)
    }

    /// Appends the low `n` (≤ 32) bits of `v`.
    @inline(__always) mutating func add(_ v: UInt64, _ n: Int) {
        acc |= (v & ((1 &<< UInt64(n)) &- 1)) &<< UInt64(count)
        count += n
        if count >= 32 {
            // Capacity is sized for the worst case by every caller; never write past it.
            if pos + 4 <= capacity {
                UnsafeMutableRawPointer(buf + pos).storeBytes(of: UInt32(truncatingIfNeeded: acc).littleEndian, as: UInt32.self)
            }
            pos += 4
            acc >>= 32
            count -= 32
        }
    }

    /// Adds the end mark (a single 1 bit), flushes the last partial byte and returns the bytes.
    mutating func close() -> [UInt8] {
        add(1, 1)
        while count > 0 {
            if pos < capacity { buf[pos] = UInt8(truncatingIfNeeded: acc) }
            pos += 1
            acc >>= 8
            count -= 8
        }
        let out = Array(UnsafeBufferPointer(start: buf, count: min(pos, capacity)))
        buf.deallocate()
        return out
    }
}

/// An FSE encoding table (zstd's `FSE_CTable`) built from a normalized distribution.
struct ZstdFSEEncoder {
    let log: Int
    var stateTable: [UInt16]
    var deltaNbBits: [UInt32]
    var deltaFindState: [Int32]

    init?(norm: [Int16], log: Int) {
        guard let spread = ZstdTables.spread(norm, log: log) else { return nil }
        let size = 1 << log
        self.log = log
        var cumul = [Int](repeating: 0, count: norm.count + 1)
        for s in 0 ..< norm.count { cumul[s + 1] = cumul[s] + (norm[s] == -1 ? 1 : max(0, Int(norm[s]))) }
        stateTable = [UInt16](repeating: 0, count: size)
        for u in 0 ..< size {
            let s = Int(spread[u])
            stateTable[cumul[s]] = UInt16(size + u)
            cumul[s] += 1
        }
        deltaNbBits = [UInt32](repeating: 0, count: norm.count)
        deltaFindState = [Int32](repeating: 0, count: norm.count)
        var total = 0
        for s in 0 ..< norm.count {
            let c = Int(norm[s])
            switch c {
            case 0:
                deltaNbBits[s] = UInt32((log + 1) << 16) &- UInt32(size)
            case -1, 1:
                deltaNbBits[s] = UInt32(log << 16) &- UInt32(size)
                deltaFindState[s] = Int32(total - 1)
                total += 1
            default:
                let maxBitsOut = log - ZstdTables.highBit(UInt32(c - 1))
                let minStatePlus = c << maxBitsOut
                deltaNbBits[s] = UInt32(maxBitsOut << 16) &- UInt32(minStatePlus)
                deltaFindState[s] = Int32(total - c)
                total += c
            }
        }
    }

    @inline(__always) func initState(_ symbol: Int) -> UInt32 {
        let d = deltaNbBits[symbol]
        let nbBitsOut = (d &+ (1 << 15)) >> 16
        let v = (nbBitsOut << 16) &- d
        return UInt32(stateTable[Int(v >> nbBitsOut) + Int(deltaFindState[symbol])])
    }

    @inline(__always) func encode(_ state: inout UInt32, _ symbol: Int, _ w: inout ZstdBitWriter) {
        let nbBitsOut = (state &+ deltaNbBits[symbol]) >> 16
        w.add(UInt64(state), Int(nbBitsOut))
        state = UInt32(stateTable[Int(state >> nbBitsOut) + Int(deltaFindState[symbol])])
    }

    @inline(__always) func flush(_ state: UInt32, _ w: inout ZstdBitWriter) {
        w.add(UInt64(state), log)
    }

    /// Normalizes `counts` (summing to `total`) to `1 << log`, every present symbol at least 1.
    static func normalize(_ counts: [Int], total: Int, log: Int) -> [Int16] {
        let size = 1 << log
        var norm = counts.map { c -> Int in c == 0 ? 0 : max(1, (c * size + total / 2) / total) }
        var diff = size - norm.reduce(0, +)
        while diff != 0 {
            if diff > 0 {
                var best = 0
                for s in counts.indices where counts[s] > counts[best] { best = s }
                norm[best] += diff
                diff = 0
            } else {
                var best = -1
                for s in norm.indices where norm[s] > 1 && (best < 0 || norm[s] > norm[best]) { best = s }
                if best < 0 { break }
                let take = min(-diff, norm[best] - 1)
                norm[best] -= take
                diff += take
            }
        }
        return norm.map { Int16($0) }
    }

    /// zstd's `FSE_optimalTableLog` (minus 2) clamped to `5...maxLog`.
    static func optimalLog(maxLog: Int, srcSize: Int, maxSymbol: Int) -> Int {
        let maxBitsSrc = ZstdTables.highBit(UInt32(max(srcSize - 1, 1))) - 2
        let minBitsSrc = ZstdTables.highBit(UInt32(max(srcSize, 1))) + 1
        let minBitsSymbols = ZstdTables.highBit(UInt32(max(maxSymbol, 1))) + 2
        var log = maxLog
        if maxBitsSrc < log { log = maxBitsSrc }
        let minBits = min(minBitsSrc, minBitsSymbols)
        if minBits > log { log = minBits }
        return min(max(log, 5), maxLog)
    }

    /// The FSE table description (zstd's `FSE_writeNCount`), or nil for an invalid distribution.
    static func writeNCount(_ norm: [Int16], log: Int) -> [UInt8]? {
        var out: [UInt8] = []
        var bits: UInt64 = 0
        var nb = 0
        @inline(__always) func put(_ v: Int, _ n: Int) {
            bits |= UInt64(v) << UInt64(nb)
            nb += n
            while nb >= 8 {
                out.append(UInt8(truncatingIfNeeded: bits))
                bits >>= 8
                nb -= 8
            }
        }
        let size = 1 << log
        put(log - 5, 4)
        var remaining = size + 1
        var threshold = size
        var nbBits = log + 1
        var symbol = 0
        var previous0 = false
        let alphabet = norm.count
        while symbol < alphabet && remaining > 1 {
            if previous0 {
                var start = symbol
                while symbol < alphabet && norm[symbol] == 0 { symbol += 1 }
                if symbol == alphabet { return nil }
                while symbol >= start + 3 {
                    start += 3
                    put(3, 2)
                }
                put(symbol - start, 2)
            }
            var count = Int(norm[symbol])
            symbol += 1
            let maxV = (2 * threshold - 1) - remaining
            remaining -= count < 0 ? -count : count
            count += 1
            if count >= threshold { count += maxV }
            put(count, count < maxV ? nbBits - 1 : nbBits)
            previous0 = count == 1
            if remaining < 1 { return nil }
            while remaining < threshold {
                nbBits -= 1
                threshold >>= 1
            }
        }
        if remaining != 1 { return nil }
        if nb > 0 { out.append(UInt8(truncatingIfNeeded: bits)) }
        return out
    }
}

/// A length-limited Huffman code over bytes, in the canonical order zstd decoders rebuild from
/// weights (RFC 8878 §4.2).
struct ZstdHuffman {
    static let maxBits = 11
    var lengths = [UInt8](repeating: 0, count: 256)
    var codes = [UInt16](repeating: 0, count: 256)
    /// Largest code length.
    var tableLog = 0
    /// Highest symbol present.
    var lastSymbol = 0

    /// A code for the histogram (at least two symbols present), or nil.
    init?(_ histogram: UnsafePointer<UInt32>) {
        var leaves: [(count: UInt32, symbol: Int)] = []
        for s in 0 ..< 256 where histogram[s] > 0 { leaves.append((histogram[s], s)) }
        guard leaves.count >= 2, let last = leaves.last else { return nil }
        lastSymbol = last.symbol
        leaves.sort { $0.count != $1.count ? $0.count < $1.count : $0.symbol < $1.symbol }
        let n = leaves.count
        // Two-queue Huffman construction over leaves sorted by frequency.
        var weight = [UInt64](repeating: 0, count: 2 * n - 1)
        var parent = [Int](repeating: 0, count: 2 * n - 1)
        for i in 0 ..< n { weight[i] = UInt64(leaves[i].count) }
        var i1 = 0, i2 = n, next = n
        @inline(__always) func pick() -> Int {
            if i1 < n && (i2 >= next || weight[i1] <= weight[i2]) { i1 += 1; return i1 - 1 }
            i2 += 1
            return i2 - 1
        }
        while next < 2 * n - 1 {
            let a = pick(), b = pick()
            weight[next] = weight[a] + weight[b]
            parent[a] = next
            parent[b] = next
            next += 1
        }
        var depth = [Int](repeating: 0, count: 2 * n - 1)
        var k = 2 * n - 3
        while k >= 0 {
            depth[k] = depth[parent[k]] + 1
            k -= 1
        }
        var len = (0 ..< n).map { depth[$0] }
        let limit = ZstdHuffman.maxBits
        if len.contains(where: { $0 > limit }) {
            // Clamp, then restore the Kraft equality: lengthen rare symbols, shorten frequent ones.
            for i in 0 ..< n { len[i] = min(len[i], limit) }
            let target = 1 << limit
            var kraft = len.reduce(0) { $0 + (1 << (limit - $1)) }
            while kraft > target {
                for i in 0 ..< n where kraft > target && len[i] < limit {
                    kraft -= 1 << (limit - len[i] - 1)
                    len[i] += 1
                }
            }
            while kraft < target {
                for i in stride(from: n - 1, through: 0, by: -1) where len[i] > 1 && kraft + (1 << (limit - len[i])) <= target {
                    kraft += 1 << (limit - len[i])
                    len[i] -= 1
                }
            }
        }
        for i in 0 ..< n { lengths[leaves[i].symbol] = UInt8(len[i]) }
        tableLog = len.max() ?? 0
        // Codes in the decoder's order: by weight (longest codes first), then by symbol.
        var rankCount = [Int](repeating: 0, count: 13)
        for s in 0 ... lastSymbol where lengths[s] > 0 { rankCount[tableLog + 1 - Int(lengths[s])] += 1 }
        var rankStart = [Int](repeating: 0, count: 13)
        var acc = 0
        for w in 1 ... tableLog {
            rankStart[w] = acc
            acc += rankCount[w] << (w - 1)
        }
        for s in 0 ... lastSymbol where lengths[s] > 0 {
            let w = tableLog + 1 - Int(lengths[s])
            codes[s] = UInt16(rankStart[w] >> (w - 1))
            rankStart[w] += 1 << (w - 1)
        }
    }

    /// Encoded bits of the histogram under this code.
    func cost(_ histogram: UnsafePointer<UInt32>) -> Int {
        var bits = 0
        for s in 0 ... lastSymbol { bits += Int(histogram[s]) * Int(lengths[s]) }
        return bits
    }

    /// The tree description (weights of symbols `0..<lastSymbol`), or nil when it can't be written.
    func description() -> [UInt8]? {
        let n = lastSymbol
        var weights = [UInt8](repeating: 0, count: n)
        for s in 0 ..< n where lengths[s] > 0 { weights[s] = UInt8(tableLog + 1 - Int(lengths[s])) }
        if let fse = ZstdHuffman.compressWeights(weights), fse.count > 1, fse.count < n / 2, fse.count < 128 {
            return [UInt8(fse.count)] + fse
        }
        guard n <= 128 else { return nil }
        var out: [UInt8] = [UInt8(127 + n)]
        var i = 0
        while i < n {
            let hi = weights[i], lo = i + 1 < n ? weights[i + 1] : 0
            out.append(hi << 4 | lo)
            i += 2
        }
        return out
    }

    /// FSE-compressed weights with two interleaved states (zstd's `HUF_compressWeights`).
    static func compressWeights(_ w: [UInt8]) -> [UInt8]? {
        let n = w.count
        guard n > 1 else { return nil }
        var counts = [Int](repeating: 0, count: 13)
        for v in w { counts[Int(v)] += 1 }
        let maxCount = counts.max() ?? 0
        if maxCount == n || maxCount == 1 { return nil }
        var maxSymbol = 12
        while maxSymbol > 0 && counts[maxSymbol] == 0 { maxSymbol -= 1 }
        counts.removeSubrange((maxSymbol + 1)...)
        let log = ZstdFSEEncoder.optimalLog(maxLog: 6, srcSize: n, maxSymbol: maxSymbol)
        let norm = ZstdFSEEncoder.normalize(counts, total: n, log: log)
        guard let header = ZstdFSEEncoder.writeNCount(norm, log: log), let ct = ZstdFSEEncoder(norm: norm, log: log) else { return nil }
        var bw = ZstdBitWriter(capacity: n + 8)
        var ip = n
        var s1: UInt32, s2: UInt32
        if n & 1 != 0 {
            ip -= 1; s1 = ct.initState(Int(w[ip]))
            ip -= 1; s2 = ct.initState(Int(w[ip]))
            ip -= 1; ct.encode(&s1, Int(w[ip]), &bw)
        } else {
            ip -= 1; s2 = ct.initState(Int(w[ip]))
            ip -= 1; s1 = ct.initState(Int(w[ip]))
        }
        if (n - 2) & 2 != 0 {
            ip -= 1; ct.encode(&s2, Int(w[ip]), &bw)
            ip -= 1; ct.encode(&s1, Int(w[ip]), &bw)
        }
        while ip > 0 {
            ip -= 1; ct.encode(&s2, Int(w[ip]), &bw)
            ip -= 1; ct.encode(&s1, Int(w[ip]), &bw)
            ip -= 1; ct.encode(&s2, Int(w[ip]), &bw)
            ip -= 1; ct.encode(&s1, Int(w[ip]), &bw)
        }
        ct.flush(s2, &bw)
        ct.flush(s1, &bw)
        return header + bw.close()
    }

    /// One Huffman bitstream of `n` symbols at `p` (written last symbol first).
    func stream(_ p: UnsafePointer<UInt8>, _ n: Int) -> [UInt8] {
        var bw = ZstdBitWriter(capacity: (n * ZstdHuffman.maxBits + 7) / 8 + 8)
        lengths.withUnsafeBufferPointer { len in
            codes.withUnsafeBufferPointer { code in
                var i = n
                while i > 0 {
                    i -= 1
                    let s = Int(p[i])
                    bw.add(UInt64(code[s]), Int(len[s]))
                }
            }
        }
        return bw.close()
    }
}

/// Compresses one zstd frame.
final class ZstdEncoder {
    /// Largest content written as a single segment (window = content); larger inputs use an
    /// 8 MiB window, well inside every decoder's limit (ruzstd allows 100 MiB).
    static let singleSegmentMax = 8 << 20
    static let windowLog = 23
    /// Most sequences in one block: every match covers at least 4 bytes.
    static let maxSequences = ZstdTables.blockSizeMax / 4 + 1

    let src: UnsafePointer<UInt8>
    let n: Int
    let maxDistance: Int
    let hashLog: Int
    let hashTable: UnsafeMutablePointer<UInt32>
    /// Shortest new-offset match: shorter ones cost more than their literals (repeat offsets
    /// still match from 4 bytes).
    var minMatch = 6
    var rep1: UInt32 = 1, rep2: UInt32 = 4, rep3: UInt32 = 8
    var out: [UInt8] = []

    // Per-block sequence store.
    let lit: UnsafeMutablePointer<UInt8>
    var litCount = 0
    let seqLL: UnsafeMutablePointer<UInt32>
    let seqML: UnsafeMutablePointer<UInt32>
    let seqOff: UnsafeMutablePointer<UInt32>
    var nbSeq = 0

    init(_ src: UnsafePointer<UInt8>, _ n: Int) {
        self.src = src
        self.n = n
        maxDistance = n <= ZstdEncoder.singleSegmentMax ? n : 1 << ZstdEncoder.windowLog
        hashLog = n <= 1 << 16 ? 13 : n <= 1 << 18 ? 15 : 16
        hashTable = .allocate(capacity: 1 << hashLog)
        hashTable.initialize(repeating: 0, count: 1 << hashLog)
        lit = .allocate(capacity: ZstdTables.blockSizeMax)
        seqLL = .allocate(capacity: ZstdEncoder.maxSequences)
        seqML = .allocate(capacity: ZstdEncoder.maxSequences)
        seqOff = .allocate(capacity: ZstdEncoder.maxSequences)
        out.reserveCapacity(n / 2 + 64)
    }

    deinit {
        hashTable.deallocate()
        lit.deallocate()
        seqLL.deallocate()
        seqML.deallocate()
        seqOff.deallocate()
    }

    /// A complete frame for `bytes`.
    static func compress(_ bytes: [UInt8], checksum: Bool = true) -> [UInt8] {
        bytes.withUnsafeBufferPointer { b in
            guard let base = b.baseAddress, b.count > 0 else {
                // Empty content: a frame with one empty raw block.
                var o: [UInt8] = [0x28, 0xB5, 0x2F, 0xFD, 0x20 | (checksum ? 4 : 0), 0, 1, 0, 0]
                if checksum { o += [0x99, 0xE9, 0xD8, 0x51] } // low 32 bits of XXH64("") = 0x51D8E999
                return o
            }
            let e = ZstdEncoder(base, b.count)
            return e.frame(checksum: checksum)
        }
    }

    func frame(checksum: Bool) -> [UInt8] {
        // Frame header (RFC 8878 §3.1.1.1).
        out += [0x28, 0xB5, 0x2F, 0xFD]
        let single = n <= ZstdEncoder.singleSegmentMax
        let fcsFlag: UInt8 = n < 256 && single ? 0 : n < 65536 + 256 ? 1 : UInt64(n) <= UInt64(UInt32.max) ? 2 : 3
        out.append(fcsFlag << 6 | (single ? 0x20 : 0) | (checksum ? 0x04 : 0))
        if !single { out.append(UInt8((ZstdEncoder.windowLog - 10) << 3)) }
        switch fcsFlag {
        case 0: out.append(UInt8(n))
        case 1: appendLE(UInt64(n - 256), 2)
        case 2: appendLE(UInt64(n), 4)
        default: appendLE(UInt64(n), 8)
        }
        var start = 0
        while start < n {
            let end = min(start + ZstdTables.blockSizeMax, n)
            block(start, end, last: end == n)
            start = end
        }
        if checksum {
            appendLE(UInt64(UInt32(truncatingIfNeeded: XXH64.hash(UnsafeRawPointer(src), n))), 4)
        }
        return out
    }

    @inline(__always) func appendLE(_ v: UInt64, _ bytes: Int) {
        for i in 0 ..< bytes { out.append(UInt8(truncatingIfNeeded: v >> (8 * UInt64(i)))) }
    }

    func blockHeader(last: Bool, type: Int, size: Int) {
        appendLE(UInt64((last ? 1 : 0) | type << 1 | size << 3), 3)
    }

    func block(_ bs: Int, _ be: Int, last: Bool) {
        let size = be - bs
        // Uniform block: RLE (memcmp of the block against itself shifted by one).
        if size == 1 || memcmp(src + bs, src + bs + 1, size - 1) == 0 {
            blockHeader(last: last, type: 1, size: size)
            out.append(src[bs])
            return
        }
        let saved = (rep1, rep2, rep3)
        findSequences(bs, be)
        var body: [UInt8] = []
        body.reserveCapacity(size)
        encodeLiterals(&body)
        encodeSequences(&body)
        if body.count >= size {
            // Incompressible: store it, and forget the offsets this attempt would have set.
            (rep1, rep2, rep3) = saved
            blockHeader(last: last, type: 0, size: size)
            out.append(contentsOf: UnsafeBufferPointer(start: src + bs, count: size))
        } else {
            blockHeader(last: last, type: 2, size: body.count)
            out += body
        }
    }

    // MARK: Match finding (zstd "fast")

    /// Finds the block's sequences: one hash probe per position (six-byte hash), repeat offset 1
    /// at the next position, zstd's "immediate repcode" after each match, and a search step that
    /// grows through incompressible stretches.
    func findSequences(_ bs: Int, _ be: Int) {
        let src = self.src, table = self.hashTable, lit = self.lit
        let seqLL = self.seqLL, seqML = self.seqML, seqOff = self.seqOff
        let shift = UInt64(64 - hashLog)
        let maxDistance = self.maxDistance
        let minMatch = self.minMatch
        let minMask: UInt64 = minMatch >= 8 ? .max : (1 << UInt64(8 * minMatch)) - 1
        var rep1 = self.rep1, rep2 = self.rep2, rep3 = self.rep3
        var litCount = 0, nbSeq = 0
        @inline(__always) func r32(_ p: Int) -> UInt32 { UInt32(littleEndian: UnsafeRawPointer(src + p).loadUnaligned(as: UInt32.self)) }
        @inline(__always) func r64(_ p: Int) -> UInt64 { UInt64(littleEndian: UnsafeRawPointer(src + p).loadUnaligned(as: UInt64.self)) }
        @inline(__always) func hash(_ p: Int) -> Int { Int(((r64(p) &<< 16) &* 227_718_039_650_203) &>> shift) }
        @inline(__always) func count(_ a: Int, _ b: Int, _ end: Int) -> Int {
            var i = 0
            while a + i + 8 <= end {
                let x = r64(a + i) ^ r64(b + i)
                if x != 0 { return i + x.trailingZeroBitCount >> 3 }
                i += 8
            }
            while a + i < end && src[a + i] == src[b + i] { i += 1 }
            return i
        }
        var ip = bs, anchor = bs
        let ilimit = be - 8
        @inline(__always) func store(_ litEnd: Int, _ offBase: UInt32, _ ml: Int) {
            let ll = litEnd - anchor
            (lit + litCount).update(from: src + anchor, count: ll)
            litCount += ll
            seqLL[nbSeq] = UInt32(ll)
            seqML[nbSeq] = UInt32(ml)
            seqOff[nbSeq] = offBase
            nbSeq += 1
        }
        @inline(__always) func afterMatch(_ start: Int) {
            if start + 2 < ilimit { table[hash(start + 2)] = UInt32(truncatingIfNeeded: start + 3) }
            if ip - 2 < ilimit && ip - 2 > start { table[hash(ip - 2)] = UInt32(truncatingIfNeeded: ip - 1) }
            // zstd's "immediate repcode": repeat offset 2 right after a match, with no literals
            // (offset code 1 with literal length 0 means repeat offset 2, and swaps the two).
            while ip < ilimit {
                let r2 = Int(rep2)
                guard r2 <= ip, r2 <= maxDistance, r32(ip - r2) == r32(ip) else { return }
                let ml = 4 + count(ip + 4, ip + 4 - r2, be)
                store(ip, 1, ml)
                swap(&rep1, &rep2)
                table[hash(ip)] = UInt32(truncatingIfNeeded: ip + 1)
                ip += ml
                anchor = ip
            }
        }
        while ip < ilimit {
            let h = hash(ip)
            let cand = Int(table[h]) - 1
            table[h] = UInt32(truncatingIfNeeded: ip + 1)
            // Repeat offset 1 at the next position (literal length ≥ 1, so offset code 1 = rep 1).
            let r1 = Int(rep1)
            if ip + 1 >= r1, r1 <= maxDistance, r32(ip + 1 - r1) == r32(ip + 1) {
                let ml = 4 + count(ip + 5, ip + 5 - r1, be)
                store(ip + 1, 1, ml)
                ip += 1 + ml
                anchor = ip
                afterMatch(ip - ml)
                continue
            }
            if cand >= 0, cand < ip, ip - cand <= maxDistance, (r64(cand) ^ r64(ip)) & minMask == 0 {
                var s = ip, c = cand
                var ml = minMatch + count(ip + minMatch, cand + minMatch, be)
                while s > anchor && c > 0 && src[s - 1] == src[c - 1] {
                    s -= 1
                    c -= 1
                    ml += 1
                }
                let offset = UInt32(s - c)
                store(s, offset + 3, ml)
                rep3 = rep2
                rep2 = rep1
                rep1 = offset
                ip = s + ml
                anchor = ip
                afterMatch(s)
                continue
            }
            ip += 1 + ((ip - anchor) >> 8)
        }
        (lit + litCount).update(from: src + anchor, count: be - anchor)
        litCount += be - anchor
        self.litCount = litCount
        self.nbSeq = nbSeq
        (self.rep1, self.rep2, self.rep3) = (rep1, rep2, rep3)
    }

    // MARK: Literals section

    func encodeLiterals(_ body: inout [UInt8]) {
        let n = litCount
        let lit = self.lit
        func rawHeader(_ type: Int) {
            if n < 32 {
                body.append(UInt8(type | n << 3))
            } else if n < 4096 {
                let v = type | 1 << 2 | n << 4
                body += [UInt8(truncatingIfNeeded: v), UInt8(truncatingIfNeeded: v >> 8)]
            } else {
                let v = type | 3 << 2 | n << 4
                body += [UInt8(truncatingIfNeeded: v), UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v >> 16)]
            }
        }
        func raw() {
            rawHeader(0)
            body.append(contentsOf: UnsafeBufferPointer(start: lit, count: n))
        }
        var hist = [UInt32](repeating: 0, count: 256)
        hist.withUnsafeMutableBufferPointer { h in
            for i in 0 ..< n { h[Int(lit[i])] &+= 1 }
        }
        if n > 1 && hist[Int(lit[0])] == UInt32(n) {
            rawHeader(1)
            body.append(lit[0])
            return
        }
        if n < 64 {
            raw()
            return
        }
        let encoded: [UInt8]? = hist.withUnsafeBufferPointer { h -> [UInt8]? in
            guard let base = h.baseAddress, let huf = ZstdHuffman(base) else { return nil }
            // Cheap estimate first: skip the work when Huffman cannot gain enough.
            let minGain = (n >> 6) + 2
            guard huf.cost(base) / 8 + 10 < n - minGain, let desc = huf.description() else { return nil }
            let single = n < 256
            var payload = desc
            if single {
                payload += huf.stream(lit, n)
            } else {
                let seg = (n + 3) / 4
                let s1 = huf.stream(lit, seg), s2 = huf.stream(lit + seg, seg), s3 = huf.stream(lit + 2 * seg, seg)
                let s4 = huf.stream(lit + 3 * seg, n - 3 * seg)
                for s in [s1, s2, s3] { payload += [UInt8(truncatingIfNeeded: s.count), UInt8(truncatingIfNeeded: s.count >> 8)] }
                payload += s1
                payload += s2
                payload += s3
                payload += s4
            }
            let comp = payload.count
            var header: [UInt8]
            if single || (n <= 1023 && comp <= 1023) {
                guard comp <= 1023 else { return nil }
                let v = 2 | (single ? 0 : 1) << 2 | n << 4 | comp << 14
                header = (0 ..< 3).map { UInt8(truncatingIfNeeded: v >> (8 * $0)) }
            } else if n <= 16383 && comp <= 16383 {
                let v = 2 | 2 << 2 | n << 4 | comp << 18
                header = (0 ..< 4).map { UInt8(truncatingIfNeeded: v >> (8 * $0)) }
            } else {
                guard comp <= 262_143 else { return nil }
                let v = 2 | 3 << 2 | n << 4 | comp << 22
                header = (0 ..< 5).map { UInt8(truncatingIfNeeded: v >> (8 * $0)) }
            }
            let total = header.count + comp
            guard total < n - minGain else { return nil }
            return header + payload
        }
        if let encoded { body += encoded } else { raw() }
    }

    // MARK: Sequences section

    static let llEncoder = ZstdFSEEncoder(norm: ZstdTables.llDefaultNorm, log: ZstdTables.llDefaultLog)
    static let ofEncoder = ZstdFSEEncoder(norm: ZstdTables.ofDefaultNorm, log: ZstdTables.ofDefaultLog)
    static let mlEncoder = ZstdFSEEncoder(norm: ZstdTables.mlDefaultNorm, log: ZstdTables.mlDefaultLog)

    /// How one sequence stream is coded: mode (0 predefined, 1 RLE, 2 compressed), the bytes of
    /// its table description and the encoding table.
    struct SeqTableChoice {
        var mode: Int
        var description: [UInt8]
        var table: ZstdFSEEncoder
    }

    static func chooseTable(_ codes: [UInt8], maxSymbol: Int, maxLog: Int, defaultNorm: [Int16], defaultLog: Int,
                            predefined: ZstdFSEEncoder) -> SeqTableChoice {
        let nbSeq = codes.count
        var counts = [Int](repeating: 0, count: maxSymbol + 1)
        for c in codes { counts[Int(c)] += 1 }
        var top = maxSymbol
        while top > 0 && counts[top] == 0 { top -= 1 }
        if nbSeq > 2, counts[top] == nbSeq {
            return SeqTableChoice(mode: 1, description: [UInt8(top)], table: predefined)
        }
        func cost(_ norm: [Int16], _ log: Int) -> Double {
            var bits = 0.0
            for s in 0 ... top where counts[s] > 0 {
                let p = s < norm.count ? max(Int(norm[s]), norm[s] == -1 ? 1 : 0) : 0
                if p == 0 { return .infinity }
                bits += Double(counts[s]) * (Double(log) - log2(Double(p)))
            }
            return bits
        }
        let predefinedCost = cost(defaultNorm, defaultLog)
        // Fitting a table only pays off with enough sequences to amortise its description.
        if nbSeq >= 16 {
            let log = ZstdFSEEncoder.optimalLog(maxLog: maxLog, srcSize: nbSeq, maxSymbol: top)
            let norm = ZstdFSEEncoder.normalize(Array(counts[0 ... top]), total: nbSeq, log: log)
            if let header = ZstdFSEEncoder.writeNCount(norm, log: log), let table = ZstdFSEEncoder(norm: norm, log: log),
               Double(header.count * 8) + cost(norm, log) < predefinedCost {
                return SeqTableChoice(mode: 2, description: header, table: table)
            }
        }
        return SeqTableChoice(mode: 0, description: [], table: predefined)
    }

    func encodeSequences(_ body: inout [UInt8]) {
        let nbSeq = self.nbSeq
        if nbSeq < 128 {
            body.append(UInt8(nbSeq))
        } else if nbSeq < 0x7F00 {
            body += [UInt8(nbSeq >> 8 + 128), UInt8(truncatingIfNeeded: nbSeq)]
        } else {
            body += [255, UInt8(truncatingIfNeeded: nbSeq - 0x7F00), UInt8(truncatingIfNeeded: (nbSeq - 0x7F00) >> 8)]
        }
        if nbSeq == 0 { return }
        guard let llP = ZstdEncoder.llEncoder, let ofP = ZstdEncoder.ofEncoder, let mlP = ZstdEncoder.mlEncoder else { return }
        let seqLL = self.seqLL, seqML = self.seqML, seqOff = self.seqOff
        var llCodes = [UInt8](repeating: 0, count: nbSeq)
        var ofCodes = [UInt8](repeating: 0, count: nbSeq)
        var mlCodes = [UInt8](repeating: 0, count: nbSeq)
        for i in 0 ..< nbSeq {
            llCodes[i] = ZstdTables.llCode(seqLL[i])
            ofCodes[i] = UInt8(ZstdTables.highBit(seqOff[i]))
            mlCodes[i] = ZstdTables.mlCode(seqML[i] - 3)
        }
        // Per stream: RLE when one symbol fills it, else the cheaper of the predefined
        // distribution and one fitted to this block (written as an FSE table description).
        let ll = ZstdEncoder.chooseTable(llCodes, maxSymbol: ZstdTables.llMaxSymbol, maxLog: ZstdTables.llMaxLog,
                                         defaultNorm: ZstdTables.llDefaultNorm, defaultLog: ZstdTables.llDefaultLog, predefined: llP)
        let of = ZstdEncoder.chooseTable(ofCodes, maxSymbol: ZstdTables.ofMaxSymbol, maxLog: ZstdTables.ofMaxLog,
                                         defaultNorm: ZstdTables.ofDefaultNorm, defaultLog: ZstdTables.ofDefaultLog, predefined: ofP)
        let ml = ZstdEncoder.chooseTable(mlCodes, maxSymbol: ZstdTables.mlMaxSymbol, maxLog: ZstdTables.mlMaxLog,
                                         defaultNorm: ZstdTables.mlDefaultNorm, defaultLog: ZstdTables.mlDefaultLog, predefined: mlP)
        body.append(UInt8(ll.mode << 6 | of.mode << 4 | ml.mode << 2))
        body += ll.description
        body += of.description
        body += ml.description
        let llRLE = ll.mode == 1, ofRLE = of.mode == 1, mlRLE = ml.mode == 1
        let llE = ll.table, ofE = of.table, mlE = ml.table

        // At most 16 + 16 + 31 extra bits and 9 + 9 + 8 state bits per sequence.
        var bw = ZstdBitWriter(capacity: nbSeq * 12 + 16)
        let last = nbSeq - 1
        var llS: UInt32 = 0, ofS: UInt32 = 0, mlS: UInt32 = 0
        if !mlRLE { mlS = mlE.initState(Int(mlCodes[last])) }
        if !ofRLE { ofS = ofE.initState(Int(ofCodes[last])) }
        if !llRLE { llS = llE.initState(Int(llCodes[last])) }
        @inline(__always) func extras(_ i: Int) {
            let lc = Int(llCodes[i]), mc = Int(mlCodes[i]), of = Int(ofCodes[i])
            bw.add(UInt64(seqLL[i] - ZstdTables.llBase[lc]), Int(ZstdTables.llBits[lc]))
            bw.add(UInt64(seqML[i] - ZstdTables.mlBase[mc]), Int(ZstdTables.mlBits[mc]))
            bw.add(UInt64(seqOff[i]), of)
        }
        extras(last)
        var i = last - 1
        while i >= 0 {
            if !ofRLE { ofE.encode(&ofS, Int(ofCodes[i]), &bw) }
            if !mlRLE { mlE.encode(&mlS, Int(mlCodes[i]), &bw) }
            if !llRLE { llE.encode(&llS, Int(llCodes[i]), &bw) }
            extras(i)
            i -= 1
        }
        if !mlRLE { mlE.flush(mlS, &bw) }
        if !ofRLE { ofE.flush(ofS, &bw) }
        if !llRLE { llE.flush(llS, &bw) }
        body += bw.close()
    }
}
