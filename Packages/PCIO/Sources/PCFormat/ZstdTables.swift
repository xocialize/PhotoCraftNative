// Shared Zstandard tables: literal/match length codes, the predefined FSE distributions and the
// FSE table spreading used by both the decoder (`ZstdDecoder`) and the encoder (`ZstdEncoder`).
// Port support for photocraft-format (crates/format/src/store.rs: the `ruzstd` codec), MIT OR
// Apache-2.0, © ArtCraft Team and the PhotoCraft contributors. Written from RFC 8878.

enum ZstdTables {
    static let magic: UInt32 = 0xFD2F_B528
    /// Largest block content (compressed or not) and largest decoded block.
    static let blockSizeMax = 128 << 10

    // MARK: Literal and match length codes (RFC 8878 §3.1.1.3.2.1.1)

    static let llBase: [UInt32] = [
        0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
        16, 18, 20, 22, 24, 28, 32, 40, 48, 64, 0x80, 0x100, 0x200, 0x400, 0x800, 0x1000,
        0x2000, 0x4000, 0x8000, 0x10000,
    ]
    static let llBits: [UInt8] = [
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        1, 1, 1, 1, 2, 2, 3, 3, 4, 6, 7, 8, 9, 10, 11, 12,
        13, 14, 15, 16,
    ]
    static let mlBase: [UInt32] = [
        3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18,
        19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34,
        35, 37, 39, 41, 43, 47, 51, 59, 67, 83, 99, 0x83, 0x103, 0x203, 0x403, 0x803,
        0x1003, 0x2003, 0x4003, 0x8003, 0x10003,
    ]
    static let mlBits: [UInt8] = [
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        1, 1, 1, 1, 2, 2, 3, 3, 4, 4, 5, 7, 8, 9, 10, 11,
        12, 13, 14, 15, 16,
    ]

    static let llMaxSymbol = 35, mlMaxSymbol = 52, ofMaxSymbol = 31
    static let llMaxLog = 9, mlMaxLog = 9, ofMaxLog = 8

    // MARK: Predefined distributions (RFC 8878 §3.1.1.3.2.2)

    static let llDefaultNorm: [Int16] = [4, 3, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1, 2, 2, 2, 2, 2, 2, 2, 2, 2, 3, 2, 1, 1, 1, 1, 1, -1, -1, -1, -1]
    static let llDefaultLog = 6
    static let mlDefaultNorm: [Int16] = [1, 4, 3, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
                                         1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, -1, -1, -1, -1, -1, -1, -1]
    static let mlDefaultLog = 6
    static let ofDefaultNorm: [Int16] = [1, 1, 1, 1, 1, 1, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, -1, -1, -1, -1, -1]
    static let ofDefaultLog = 5

    /// Literal length → code.
    @inline(__always) static func llCode(_ ll: UInt32) -> UInt8 {
        if ll < 16 { return UInt8(ll) }
        if ll < 64 { return llCodeSmall[Int(ll)] }
        return UInt8(31 - ll.leadingZeroBitCount + 19)
    }

    static let llCodeSmall: [UInt8] = {
        var t = [UInt8](repeating: 0, count: 64)
        for code in 0 ..< 25 {
            let base = Int(llBase[code])
            for v in base ..< min(64, base + (1 << Int(llBits[code]))) { t[v] = UInt8(code) }
        }
        return t
    }()

    /// `matchLength - 3` → code.
    @inline(__always) static func mlCode(_ mlBase3: UInt32) -> UInt8 {
        if mlBase3 < 128 { return mlCodeSmall[Int(mlBase3)] }
        return UInt8(31 - mlBase3.leadingZeroBitCount + 36)
    }

    static let mlCodeSmall: [UInt8] = {
        var t = [UInt8](repeating: 0, count: 128)
        for code in 0 ..< 43 {
            let base = Int(mlBase[code]) - 3
            for v in base ..< min(128, base + (1 << Int(mlBits[code]))) { t[v] = UInt8(code) }
        }
        return t
    }()

    @inline(__always) static func highBit(_ v: UInt32) -> Int { 31 - v.leadingZeroBitCount }

    /// FSE symbol spreading (RFC 8878 §4.1.1): the symbol of every state of a table with
    /// normalized counts `norm` (−1 = "less than one") and `log`. Returns nil for an invalid
    /// distribution (wrong total or spread not returning to 0).
    static func spread(_ norm: [Int16], log: Int) -> [UInt8]? {
        let size = 1 << log
        var table = [UInt8](repeating: 0, count: size)
        var high = size - 1
        var total = 0
        for (s, c) in norm.enumerated() {
            if c == -1 {
                guard high >= 0 else { return nil }
                table[high] = UInt8(truncatingIfNeeded: s)
                high -= 1
                total += 1
            } else if c > 0 {
                total += Int(c)
            } else if c < -1 {
                return nil
            }
        }
        guard total == size else { return nil }
        let step = (size >> 1) + (size >> 3) + 3
        let mask = size - 1
        var pos = 0
        for (s, c) in norm.enumerated() where c > 0 {
            for _ in 0 ..< Int(c) {
                table[pos] = UInt8(truncatingIfNeeded: s)
                pos = (pos + step) & mask
                while pos > high { pos = (pos + step) & mask }
            }
        }
        guard pos == 0 else { return nil }
        return table
    }
}
