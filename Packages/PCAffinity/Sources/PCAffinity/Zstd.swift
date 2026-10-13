// Port of photocraft-affinity (crates/affinity/src/container.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
// zstd archive entries (compression method 2). photocraft decodes them with the ruzstd crate (frame
// by frame, window capped at 64 MiB, each frame read through `take(left + 1)`). Apple's Compression
// framework has no zstd, so this is a bounded Zstandard decoder written from RFC 8878: raw, RLE and
// compressed blocks, Huffman literals (1 or 4 streams, FSE-compressed or direct weights, treeless
// reuse), FSE sequences (predefined, RLE, compressed and repeat modes), repeat offsets and the XXH64
// content checksum. No dictionaries (photocraft supplies none), no skippable frames (ruzstd rejects
// them as a frame).
//
// Hostile input: every table is validated when it is built (so every state index stays inside its
// table), every length is checked against the block before it is read, matches may only reach back
// into the current frame, a block may not produce more than 128 KiB, and output stops at the entry's
// declared size.

enum Zstd {
    static let maxBlockSize = 128 << 10
    static let magic: UInt64 = 0xFD2F_B528

    enum Failure: Error {
        case corrupt
        /// The entry would decode past its declared size.
        case outputLimit
    }

    /// Decode every frame of an entry into exactly as many bytes as it declares, or fail the way
    /// photocraft's `unzstd` does: "corrupt compressed entry" for damaged data, "archive entry size
    /// mismatch" for data that decodes past `size`.
    static func decompress(_ data: ArraySlice<UInt8>, size: Int, maxWindow: UInt64) throws(AffinityError) -> [UInt8] {
        let src = Array(data)
        var out: [UInt8] = []
        out.reserveCapacity(min(size, 64 << 20))
        var pos = 0
        // Entries may hold several concatenated frames.
        while pos < src.count {
            let start = out.count
            var frame = FrameDecoder(src: src, pos: pos, maxWindow: maxWindow)
            do {
                try frame.decode(into: &out, limit: size)
            } catch .outputLimit {
                throw .malformed("archive entry size mismatch")
            } catch {
                throw .malformed("corrupt compressed entry")
            }
            pos = frame.pos
            guard out.count > start else { throw .malformed("corrupt compressed entry") }
        }
        return out
    }

    // MARK: - Bit readers

    /// A backward bitstream (Huffman streams, FSE-coded weights, sequences): read from the end towards
    /// the start, the last byte's highest set bit marks where data begins. Bits before the start read
    /// as zeros; `offset` then goes negative, which callers check.
    struct BackwardBits {
        let src: [UInt8]
        let start: Int
        /// Bits not yet consumed, counted from `start`.
        var offset: Int

        init(_ src: [UInt8], _ start: Int, _ end: Int) throws(Failure) {
            guard start >= 0, end > start, end <= src.count else { throw .corrupt }
            let last = src[end - 1]
            guard last != 0 else { throw .corrupt }
            self.src = src
            self.start = start
            offset = (end - start - 1) * 8 + (7 - last.leadingZeroBitCount)
        }

        /// The next `n` (≤ 32) bits.
        @inline(__always)
        mutating func read(_ n: Int) -> Int {
            if n <= 0 { return 0 }
            offset -= n
            var lo = offset
            var count = n
            var shift = 0
            if lo < 0 {
                count += lo
                shift = -lo
                lo = 0
                if count <= 0 { return 0 }
            }
            // lo + count never exceeds the bits that were available, so these bytes are in range.
            let byte = start + (lo >> 3)
            let bit = lo & 7
            let needed = (bit + count + 7) >> 3
            var v: UInt64 = 0
            for k in 0..<needed { v |= UInt64(src[byte + k]) << UInt64(8 * k) }
            v = (v >> UInt64(bit)) & ((1 << UInt64(count)) - 1)
            return Int(v) << shift
        }
    }

    // MARK: - FSE

    struct FSEEntry: Sendable {
        var symbol: UInt8
        var bits: UInt8
        var base: UInt16
    }

    /// An FSE decoding table: `entries.count == 1 << log`, and for every entry
    /// `base + (1 << bits) <= entries.count`, so a state update never leaves the table.
    struct FSETable: Sendable {
        var log: Int
        var entries: [FSEEntry]

        static func rle(_ symbol: UInt8) -> FSETable {
            FSETable(log: 0, entries: [FSEEntry(symbol: symbol, bits: 0, base: 0)])
        }

        /// Spread normalized counts (−1 = "less than one") over the table, RFC 8878 §4.1.1.
        static func build(_ counts: [Int16], log: Int) throws(Failure) -> FSETable {
            guard log >= 0, log <= 15, !counts.isEmpty, counts.count <= 256 else { throw .corrupt }
            let size = 1 << log
            var symbols = [UInt8](repeating: 0, count: size)
            var next = [Int](repeating: 0, count: counts.count)
            var high = size
            for (s, c) in counts.enumerated() where c == -1 {
                guard high > 0 else { throw .corrupt }
                high -= 1
                symbols[high] = UInt8(s)
                next[s] = 1
            }
            let step = (size >> 1) + (size >> 3) + 3
            let mask = size - 1
            var pos = 0
            for (s, c) in counts.enumerated() where c > 0 {
                next[s] = Int(c)
                for _ in 0..<Int(c) {
                    guard pos < high else { throw .corrupt }
                    symbols[pos] = UInt8(s)
                    var steps = 0
                    repeat {
                        pos = (pos + step) & mask
                        steps += 1
                    } while pos >= high && steps <= size
                    guard steps <= size else { throw .corrupt }
                }
            }
            guard pos == 0 else { throw .corrupt }
            var entries = [FSEEntry](repeating: FSEEntry(symbol: 0, bits: 0, base: 0), count: size)
            for i in 0..<size {
                let s = Int(symbols[i])
                let state = next[s]
                guard state > 0 else { throw .corrupt }
                next[s] = state + 1
                let bits = log - (Int.bitWidth - 1 - state.leadingZeroBitCount)
                guard bits >= 0 else { throw .corrupt }
                let base = (state << bits) - size
                guard base >= 0, base + (1 << bits) <= size else { throw .corrupt }
                entries[i] = FSEEntry(symbol: UInt8(s), bits: UInt8(bits), base: UInt16(base))
            }
            return FSETable(log: log, entries: entries)
        }

        static func predefined(_ counts: [Int16], log: Int) -> FSETable {
            // The RFC's default distributions are valid; the fallback only keeps this trap-free.
            (try? build(counts, log: log)) ?? rle(0)
        }
    }

    static let predefinedLiteralLengths = FSETable.predefined([
        4, 3, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1,
        2, 2, 2, 2, 2, 2, 2, 2, 2, 3, 2, 1, 1, 1, 1, 1,
        -1, -1, -1, -1,
    ], log: 6)
    static let predefinedMatchLengths = FSETable.predefined([
        1, 4, 3, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, -1, -1,
        -1, -1, -1, -1, -1,
    ], log: 6)
    static let predefinedOffsets = FSETable.predefined([
        1, 1, 1, 1, 1, 1, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1,
        1, 1, 1, 1, 1, 1, 1, 1, -1, -1, -1, -1, -1,
    ], log: 5)

    static let literalLengthBase: [Int] = Array(0...15) + [16, 18, 20, 22, 24, 28, 32, 40, 48, 64, 128, 256, 512, 1024, 2048, 4096, 8192, 16384, 32768, 65536]
    static let literalLengthBits: [Int] = Array(repeating: 0, count: 16) + [1, 1, 1, 1, 2, 2, 3, 3, 4, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]
    static let matchLengthBase: [Int] = Array(3...34) + [35, 37, 39, 41, 43, 47, 51, 59, 67, 83, 99, 131, 259, 515, 1027, 2051, 4099, 8195, 16387, 32771, 65539]
    static let matchLengthBits: [Int] = Array(repeating: 0, count: 32) + [1, 1, 1, 1, 2, 2, 3, 3, 4, 4, 5, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]

    enum SequenceKind {
        case literalLength, offset, matchLength

        var maxLog: Int { self == .offset ? 8 : 9 }
        var maxSymbol: Int {
            switch self {
            case .literalLength: 35
            case .offset: 31
            case .matchLength: 52
            }
        }
        var predefined: FSETable {
            switch self {
            case .literalLength: Zstd.predefinedLiteralLengths
            case .offset: Zstd.predefinedOffsets
            case .matchLength: Zstd.predefinedMatchLengths
            }
        }
    }

    // MARK: - Huffman

    /// A Huffman decoding table of `1 << maxBits` entries: symbol in the low byte, code length above.
    struct HuffmanTable: Sendable {
        var maxBits: Int
        var entries: [UInt16]

        /// From the stated weights; the last symbol's weight is implied (RFC 8878 §4.2.1).
        init(weights stated: [UInt8]) throws(Failure) {
            guard !stated.isEmpty, stated.count <= 255 else { throw .corrupt }
            var sum = 0
            for w in stated {
                guard w <= 11 else { throw .corrupt }
                if w > 0 { sum += 1 << (Int(w) - 1) }
            }
            guard sum > 0 else { throw .corrupt }
            let maxBits = Int.bitWidth - sum.leadingZeroBitCount
            guard maxBits <= 11 else { throw .corrupt }
            let leftover = (1 << maxBits) - sum
            guard leftover > 0, leftover & (leftover - 1) == 0 else { throw .corrupt }
            let weights = stated + [UInt8(Int.bitWidth - leftover.leadingZeroBitCount)]
            let size = 1 << maxBits
            var rankCount = [Int](repeating: 0, count: maxBits + 2)
            for w in weights where w > 0 { rankCount[maxBits + 1 - Int(w)] += 1 }
            var rankIndex = [Int](repeating: 0, count: maxBits + 2)
            for bits in stride(from: maxBits, through: 1, by: -1) {
                rankIndex[bits - 1] = rankIndex[bits] + rankCount[bits] * (1 << (maxBits - bits))
            }
            guard rankIndex[0] == size else { throw .corrupt }
            var entries = [UInt16](repeating: 0, count: size)
            for (symbol, w) in weights.enumerated() where w > 0 {
                let bits = maxBits + 1 - Int(w)
                let code = rankIndex[bits]
                let length = 1 << (maxBits - bits)
                guard code + length <= size else { throw .corrupt }
                for k in code..<(code + length) { entries[k] = UInt16(symbol) | UInt16(bits) << 8 }
                rankIndex[bits] += length
            }
            self.maxBits = maxBits
            self.entries = entries
        }
    }

    // MARK: - Frames

    struct FrameDecoder {
        let src: [UInt8]
        var pos: Int
        let maxWindow: UInt64
        /// Repeat offsets, reset per frame.
        var rep = (1, 4, 8)
        /// Tables kept for treeless literals and repeat-mode sequences.
        var huffman: HuffmanTable?
        var literalLengths: FSETable?
        var offsets: FSETable?
        var matchLengths: FSETable?

        init(src: [UInt8], pos: Int, maxWindow: UInt64) {
            self.src = src
            self.pos = pos
            self.maxWindow = maxWindow
        }

        private mutating func byte() throws(Failure) -> UInt8 {
            guard pos < src.count else { throw .corrupt }
            defer { pos += 1 }
            return src[pos]
        }

        private mutating func le(_ n: Int) throws(Failure) -> UInt64 {
            guard n >= 0, src.count - pos >= n else { throw .corrupt }
            var v: UInt64 = 0
            for k in 0..<n { v |= UInt64(src[pos + k]) << UInt64(8 * k) }
            pos += n
            return v
        }

        private mutating func take(_ n: Int) throws(Failure) -> Range<Int> {
            guard n >= 0, src.count - pos >= n else { throw .corrupt }
            defer { pos += n }
            return pos..<(pos + n)
        }

        /// One frame, appended to `out`, which may not grow past `limit` bytes.
        mutating func decode(into out: inout [UInt8], limit: Int) throws(Failure) {
            guard try le(4) == Zstd.magic else { throw .corrupt }
            let descriptor = try byte()
            let fcsFlag = Int(descriptor >> 6)
            let singleSegment = descriptor & 0x20 != 0
            let hasChecksum = descriptor & 0x04 != 0
            guard descriptor & 0x08 == 0 else { throw .corrupt }
            var window: UInt64 = 0
            if !singleSegment {
                let w = try byte()
                let base: UInt64 = 1 << (10 + UInt64(w >> 3))
                window = base + (base / 8) * UInt64(w & 7)
            }
            let dictionary = try le([0, 1, 2, 4][Int(descriptor & 3)])
            guard dictionary == 0 else { throw .corrupt }
            let fcsBytes = fcsFlag == 0 ? (singleSegment ? 1 : 0) : [0, 2, 4, 8][fcsFlag]
            var contentSize: UInt64?
            if fcsBytes > 0 {
                let v = try le(fcsBytes)
                contentSize = fcsBytes == 2 ? v + 256 : v
            }
            if singleSegment { window = contentSize ?? 0 }
            guard window <= maxWindow else { throw .corrupt }
            let frameStart = out.count
            while true {
                let header = try le(3)
                let last = header & 1 != 0
                let size = Int(header >> 3)
                guard size <= Zstd.maxBlockSize else { throw .corrupt }
                switch (header >> 1) & 3 {
                case 0:
                    let r = try take(size)
                    guard limit - out.count >= size else { throw .outputLimit }
                    out.append(contentsOf: src[r])
                case 1:
                    let b = try byte()
                    guard limit - out.count >= size else { throw .outputLimit }
                    out.append(contentsOf: repeatElement(b, count: size))
                case 2:
                    let r = try take(size)
                    try compressedBlock(r, into: &out, frameStart: frameStart, limit: limit)
                default:
                    throw .corrupt
                }
                if last { break }
            }
            if hasChecksum {
                let stored = UInt32(truncatingIfNeeded: try le(4))
                let actual = out.withUnsafeBufferPointer { p in
                    Checksum.xxh64(UnsafeBufferPointer(rebasing: p[frameStart...]))
                }
                guard UInt32(truncatingIfNeeded: actual) == stored else { throw .corrupt }
            }
            if let contentSize, UInt64(out.count - frameStart) != contentSize { throw .corrupt }
        }

        // MARK: Blocks

        private mutating func compressedBlock(_ block: Range<Int>, into out: inout [UInt8], frameStart: Int, limit: Int) throws(Failure) {
            var p = block.lowerBound
            let end = block.upperBound
            let blockStart = out.count
            let literals = try readLiterals(&p, end)

            guard p < end else { throw .corrupt }
            let b0 = Int(src[p])
            p += 1
            var count: Int
            if b0 < 128 {
                count = b0
            } else if b0 < 255 {
                guard p < end else { throw .corrupt }
                count = ((b0 - 128) << 8) + Int(src[p])
                p += 1
            } else {
                guard end - p >= 2 else { throw .corrupt }
                count = Int(src[p]) + (Int(src[p + 1]) << 8) + 0x7F00
                p += 2
            }
            if count == 0 {
                // Literals only; the sequence section ends here.
                guard p == end else { throw .corrupt }
                guard limit - out.count >= literals.count else { throw .outputLimit }
                out.append(contentsOf: literals)
                guard out.count - blockStart <= Zstd.maxBlockSize else { throw .corrupt }
                return
            }
            guard p < end else { throw .corrupt }
            let modes = src[p]
            p += 1
            guard modes & 3 == 0 else { throw .corrupt }
            let ll = try sequenceTable(Int(modes >> 6), .literalLength, &p, end, previous: literalLengths)
            let of = try sequenceTable(Int((modes >> 4) & 3), .offset, &p, end, previous: offsets)
            let ml = try sequenceTable(Int((modes >> 2) & 3), .matchLength, &p, end, previous: matchLengths)
            literalLengths = ll
            offsets = of
            matchLengths = ml

            var bits = try BackwardBits(src, p, end)
            var llState = bits.read(ll.log)
            var ofState = bits.read(of.log)
            var mlState = bits.read(ml.log)
            var used = 0
            for i in 0..<count {
                let lle = ll.entries[llState]
                let ofe = of.entries[ofState]
                let mle = ml.entries[mlState]
                let ofCode = Int(ofe.symbol)
                let llCode = Int(lle.symbol)
                let mlCode = Int(mle.symbol)
                guard ofCode <= 31, llCode < Zstd.literalLengthBase.count, mlCode < Zstd.matchLengthBase.count else { throw .corrupt }
                // Extra bits in the order offset, match length, literal length.
                let offsetValue = (1 << ofCode) + bits.read(ofCode)
                let matchLength = Zstd.matchLengthBase[mlCode] + bits.read(Zstd.matchLengthBits[mlCode])
                let literalLength = Zstd.literalLengthBase[llCode] + bits.read(Zstd.literalLengthBits[llCode])
                if i + 1 < count {
                    llState = Int(lle.base) + bits.read(Int(lle.bits))
                    mlState = Int(mle.base) + bits.read(Int(mle.bits))
                    ofState = Int(ofe.base) + bits.read(Int(ofe.bits))
                }
                let offset = resolve(offsetValue, literalLength: literalLength)
                guard literalLength <= literals.count - used else { throw .corrupt }
                guard limit - out.count >= literalLength else { throw .outputLimit }
                out.append(contentsOf: literals[used..<(used + literalLength)])
                used += literalLength
                // Matches reach back only into this frame (no dictionaries).
                guard offset > 0, offset <= out.count - frameStart else { throw .corrupt }
                guard limit - out.count >= matchLength else { throw .outputLimit }
                Zstd.copyMatch(&out, offset: offset, length: matchLength)
                guard out.count - blockStart <= Zstd.maxBlockSize else { throw .corrupt }
            }
            // The sequence bitstream must be consumed exactly.
            guard bits.offset == 0 else { throw .corrupt }
            let rest = literals.count - used
            guard limit - out.count >= rest else { throw .outputLimit }
            out.append(contentsOf: literals[used...])
            guard out.count - blockStart <= Zstd.maxBlockSize else { throw .corrupt }
        }

        /// Offset of a sequence from its offset value, updating the repeat offsets (RFC 8878 §3.1.2.5).
        /// Returns 0 (rejected by the caller) for the invalid "first repeat offset minus one" of 0.
        private mutating func resolve(_ value: Int, literalLength: Int) -> Int {
            if value > 3 {
                let o = value - 3
                rep = (o, rep.0, rep.1)
                return o
            }
            let index = value - 1 + (literalLength == 0 ? 1 : 0)
            switch index {
            case 0:
                return rep.0
            case 1:
                let o = rep.1
                rep = (o, rep.0, rep.2)
                return o
            case 2:
                let o = rep.2
                rep = (o, rep.0, rep.1)
                return o
            default:
                let o = rep.0 - 1
                rep = (o, rep.0, rep.1)
                return o
            }
        }

        private mutating func sequenceTable(_ mode: Int, _ kind: SequenceKind, _ p: inout Int, _ end: Int, previous: FSETable?) throws(Failure) -> FSETable {
            switch mode {
            case 0:
                return kind.predefined
            case 1:
                guard p < end else { throw .corrupt }
                let symbol = src[p]
                p += 1
                guard Int(symbol) <= kind.maxSymbol else { throw .corrupt }
                return .rle(symbol)
            case 2:
                return try readFSE(&p, end, maxLog: kind.maxLog, maxSymbol: kind.maxSymbol)
            default:
                guard let previous else { throw .corrupt }
                return previous
            }
        }

        // MARK: Literals

        private mutating func readLiterals(_ p: inout Int, _ end: Int) throws(Failure) -> [UInt8] {
            guard p < end else { throw .corrupt }
            let b0 = Int(src[p])
            let type = b0 & 3
            let format = (b0 >> 2) & 3
            if type < 2 {
                var regenerated: Int
                var header: Int
                switch format {
                case 0, 2:
                    regenerated = b0 >> 3
                    header = 1
                case 1:
                    guard end - p >= 2 else { throw .corrupt }
                    regenerated = (b0 >> 4) + (Int(src[p + 1]) << 4)
                    header = 2
                default:
                    guard end - p >= 3 else { throw .corrupt }
                    regenerated = (b0 >> 4) + (Int(src[p + 1]) << 4) + (Int(src[p + 2]) << 12)
                    header = 3
                }
                guard regenerated <= Zstd.maxBlockSize else { throw .corrupt }
                p += header
                if type == 0 {
                    guard end - p >= regenerated else { throw .corrupt }
                    defer { p += regenerated }
                    return Array(src[p..<(p + regenerated)])
                }
                guard p < end else { throw .corrupt }
                defer { p += 1 }
                return [UInt8](repeating: src[p], count: regenerated)
            }
            var regenerated: Int
            var compressed: Int
            var header: Int
            switch format {
            case 0, 1:
                guard end - p >= 3 else { throw .corrupt }
                let c = b0 | Int(src[p + 1]) << 8 | Int(src[p + 2]) << 16
                regenerated = (c >> 4) & 0x3FF
                compressed = (c >> 14) & 0x3FF
                header = 3
            case 2:
                guard end - p >= 4 else { throw .corrupt }
                let c = b0 | Int(src[p + 1]) << 8 | Int(src[p + 2]) << 16 | Int(src[p + 3]) << 24
                regenerated = (c >> 4) & 0x3FFF
                compressed = (c >> 18) & 0x3FFF
                header = 4
            default:
                guard end - p >= 5 else { throw .corrupt }
                let c = b0 | Int(src[p + 1]) << 8 | Int(src[p + 2]) << 16 | Int(src[p + 3]) << 24 | Int(src[p + 4]) << 32
                regenerated = (c >> 4) & 0x3FFFF
                compressed = (c >> 22) & 0x3FFFF
                header = 5
            }
            guard regenerated <= Zstd.maxBlockSize else { throw .corrupt }
            p += header
            guard end - p >= compressed else { throw .corrupt }
            var q = p
            let streamEnd = p + compressed
            let table: HuffmanTable
            if type == 2 {
                table = try readHuffmanTable(&q, streamEnd)
                huffman = table
            } else {
                guard let previous = huffman else { throw .corrupt }
                table = previous
            }
            let literals = try huffmanLiterals(q, streamEnd, streams: format == 0 ? 1 : 4, count: regenerated, table)
            p = streamEnd
            return literals
        }

        private func readHuffmanTable(_ q: inout Int, _ end: Int) throws(Failure) -> HuffmanTable {
            guard q < end else { throw .corrupt }
            let header = Int(src[q])
            q += 1
            var weights: [UInt8] = []
            if header < 128 {
                // FSE-compressed weights in `header` bytes: a table header, then two interleaved states.
                guard header > 0, end - q >= header else { throw .corrupt }
                let weightsEnd = q + header
                var h = q
                let fse = try readFSE(&h, weightsEnd, maxLog: 6, maxSymbol: 12)
                var bits = try BackwardBits(src, h, weightsEnd)
                var s1 = bits.read(fse.log)
                var s2 = bits.read(fse.log)
                while true {
                    guard weights.count < 255 else { throw .corrupt }
                    weights.append(fse.entries[s1].symbol)
                    s1 = Int(fse.entries[s1].base) + bits.read(Int(fse.entries[s1].bits))
                    if bits.offset < 0 {
                        guard weights.count < 255 else { throw .corrupt }
                        weights.append(fse.entries[s2].symbol)
                        break
                    }
                    guard weights.count < 255 else { throw .corrupt }
                    weights.append(fse.entries[s2].symbol)
                    s2 = Int(fse.entries[s2].base) + bits.read(Int(fse.entries[s2].bits))
                    if bits.offset < 0 {
                        guard weights.count < 255 else { throw .corrupt }
                        weights.append(fse.entries[s1].symbol)
                        break
                    }
                }
                q = weightsEnd
            } else {
                // Direct weights, four bits each, the first in the high nibble.
                let n = header - 127
                let bytes = (n + 1) / 2
                guard end - q >= bytes else { throw .corrupt }
                for i in 0..<n {
                    let b = src[q + i / 2]
                    weights.append(i & 1 == 0 ? b >> 4 : b & 0x0F)
                }
                q += bytes
            }
            return try HuffmanTable(weights: weights)
        }

        private func huffmanLiterals(_ start: Int, _ end: Int, streams: Int, count: Int, _ table: HuffmanTable) throws(Failure) -> [UInt8] {
            var out: [UInt8] = []
            out.reserveCapacity(count)
            if streams == 1 {
                try huffmanStream(start, end, count: count, table, into: &out)
                return out
            }
            // Four streams behind a jump table of three little-endian sizes.
            guard end - start >= 6 else { throw .corrupt }
            let sizes = (0..<3).map { Int(src[start + 2 * $0]) | Int(src[start + 2 * $0 + 1]) << 8 }
            var p = start + 6
            guard sizes[0] + sizes[1] + sizes[2] < end - p else { throw .corrupt }
            let segment = (count + 3) / 4
            guard count - 3 * segment >= 0 else { throw .corrupt }
            for k in 0..<4 {
                let length = k < 3 ? sizes[k] : end - p
                try huffmanStream(p, p + length, count: k < 3 ? segment : count - 3 * segment, table, into: &out)
                p += length
            }
            return out
        }

        private func huffmanStream(_ start: Int, _ end: Int, count: Int, _ table: HuffmanTable, into out: inout [UInt8]) throws(Failure) {
            var bits = try BackwardBits(src, start, end)
            let mask = (1 << table.maxBits) - 1
            var state = bits.read(table.maxBits)
            for _ in 0..<count {
                let e = table.entries[state]
                out.append(UInt8(truncatingIfNeeded: e))
                let n = Int(e >> 8)
                state = ((state << n) | bits.read(n)) & mask
            }
            // Every bit of the stream must be used: the final state then reaches past its start.
            guard bits.offset == -table.maxBits else { throw .corrupt }
        }

        // MARK: FSE table descriptions

        /// A normalized-count table description (RFC 8878 §4.1.1), read forward from `p`.
        private func readFSE(_ p: inout Int, _ end: Int, maxLog: Int, maxSymbol: Int) throws(Failure) -> FSETable {
            let start = p
            var bitPos = 0
            func peek(_ n: Int) -> Int {
                var v = 0
                for k in 0..<n {
                    let at = bitPos + k
                    let byte = start + (at >> 3)
                    if byte < end, (src[byte] >> UInt8(at & 7)) & 1 != 0 { v |= 1 << k }
                }
                return v
            }
            let log = peek(4) + 5
            bitPos += 4
            guard log <= maxLog else { throw .corrupt }
            var remaining = (1 << log) + 1
            var threshold = 1 << log
            var nbBits = log + 1
            var counts: [Int16] = []
            var previousZero = false
            while remaining > 1, counts.count <= maxSymbol {
                if previousZero {
                    var zeros = 0
                    while true {
                        let r = peek(2)
                        bitPos += 2
                        zeros += r
                        guard counts.count + zeros <= maxSymbol + 1 else { throw .corrupt }
                        if r != 3 { break }
                    }
                    counts.append(contentsOf: repeatElement(0, count: zeros))
                    if counts.count > maxSymbol { break }
                }
                let max = (2 * threshold - 1) - remaining
                let v = peek(nbBits)
                var value: Int
                if v & (threshold - 1) < max {
                    value = v & (threshold - 1)
                    bitPos += nbBits - 1
                } else {
                    value = v & (2 * threshold - 1)
                    if value >= threshold { value -= max }
                    bitPos += nbBits
                }
                let probability = value - 1
                remaining -= abs(probability)
                counts.append(Int16(probability))
                previousZero = probability == 0
                if remaining < threshold {
                    if remaining <= 1 { break }
                    nbBits = Int.bitWidth - remaining.leadingZeroBitCount
                    threshold = 1 << (nbBits - 1)
                }
            }
            guard remaining == 1, counts.count <= maxSymbol + 1 else { throw .corrupt }
            let consumed = (bitPos + 7) / 8
            guard consumed <= end - start else { throw .corrupt }
            p = start + consumed
            return try FSETable.build(counts, log: log)
        }
    }

    /// LZ77 copy of `length` bytes from `offset` back (0 < offset ≤ out.count), overlap allowed.
    static func copyMatch(_ out: inout [UInt8], offset: Int, length: Int) {
        guard length > 0, offset > 0, offset <= out.count else { return }
        let dst = out.count
        let from = dst - offset
        out.append(contentsOf: repeatElement(0, count: length))
        out.withUnsafeMutableBufferPointer { p in
            // Forward byte order makes an overlapping match repeat its pattern.
            for i in 0..<length { p[dst + i] = p[from + i] }
        }
    }
}
