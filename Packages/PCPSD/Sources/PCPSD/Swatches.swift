// Colour swatch files: Photoshop `.aco` (versions 1 and 2) and Adobe Swatch Exchange `.ase`.
// Port of photocraft-psd (crates/psd/src/aco.rs, ase.rs), MIT OR Apache-2.0, © ArtCraft Team and the
// PhotoCraft contributors.
//
// .aco: a version 1 section (u16 version, u16 count, colour records of a u16 space and four u16
// values), usually followed by a version 2 section with names (u32 UTF-16 count incl. the NUL).
// CMYK stores the complement of the ink; Lab L × 100 and signed a/b × 100; gray 0...10000.
// .ase: `ASEF`, u16 major 1, u16 minor, u32 block count, blocks of u16 type, u32 length, body:
// 0xC001 group start (name), 0xC002 group end, 0x0001 colour (name, model, f32 components, u16 type).

import Foundation

// MARK: - .aco

public enum PSDAco {
    public static let maxSwatches = Int(UInt16.max)
    public static let maxNameUnits = 1024

    /// A swatch colour as stored, at 16-bit precision.
    public enum Color: Hashable, Sendable {
        case rgb(UInt16, UInt16, UInt16)
        /// Hue 0...65535 (0...360°), saturation, brightness.
        case hsb(UInt16, UInt16, UInt16)
        /// Ink amounts, 65535 = 100 % (the file stores the complement).
        case cmyk(UInt16, UInt16, UInt16, UInt16)
        /// L × 100 (0...10000), a × 100, b × 100.
        case lab(l: UInt16, a: Int16, b: Int16)
        /// 0 black ... 10000 white.
        case gray(UInt16)
        /// Any other space (colour books, …), kept verbatim.
        case other(space: UInt16, values: [UInt16])

        public init(space: UInt16, values v: [UInt16]) {
            switch space {
            case 0: self = .rgb(v[0], v[1], v[2])
            case 1: self = .hsb(v[0], v[1], v[2])
            case 2: self = .cmyk(UInt16.max - v[0], UInt16.max - v[1], UInt16.max - v[2], UInt16.max - v[3])
            case 7: self = .lab(l: v[0], a: Int16(bitPattern: v[1]), b: Int16(bitPattern: v[2]))
            case 8: self = .gray(v[0])
            default: self = .other(space: space, values: v)
            }
        }

        public var record: (space: UInt16, values: [UInt16]) {
            switch self {
            case let .rgb(r, g, b): (0, [r, g, b, 0])
            case let .hsb(h, s, b): (1, [h, s, b, 0])
            case let .cmyk(c, m, y, k): (2, [c, m, y, k].map { UInt16.max - $0 })
            case let .lab(l, a, b): (7, [l, UInt16(bitPattern: a), UInt16(bitPattern: b), 0])
            case let .gray(g): (8, [g, 0, 0, 0])
            case let .other(space, values): (space, Array((values + [0, 0, 0, 0]).prefix(4)))
            }
        }
    }

    public struct Swatch: Hashable, Sendable {
        public var name: String
        public var color: Color
        public init(name: String, color: Color) {
            self.name = name
            self.color = color
        }
    }

    public struct File: Hashable, Sendable {
        public var swatches: [Swatch]
        /// The file had a version 2 section (names).
        public var hasNames: Bool
    }

    static func readName(_ r: inout ByteReader) throws -> String {
        let n = UInt64(try r.u32())
        try r.checkCount(n, minItemSize: 2)
        var units: [UInt16] = []
        for _ in 0 ..< n {
            let u = try r.u16()
            if units.count < maxNameUnits { units.append(u) }
        }
        while units.last == 0 { units.removeLast() }
        return String(decoding: units, as: UTF16.self)
    }

    static func readSection(_ r: inout ByteReader, named: Bool) throws -> [Swatch] {
        let count = try r.u16()
        try r.checkCount(UInt64(count), minItemSize: named ? 14 : 10)
        return try (0 ..< count).map { _ in
            let space = try r.u16()
            let v = [try r.u16(), try r.u16(), try r.u16(), try r.u16()]
            return Swatch(name: named ? try readName(&r) : "", color: Color(space: space, values: v))
        }
    }

    /// Parses an `.aco` file (version 1 with an optional version 2 section, or version 2 only).
    public static func parse(_ data: Data) throws -> File {
        try data.withByteReader { r in
            let v = try r.u16()
            switch v {
            case 1:
                let v1 = try readSection(&r, named: false)
                if r.remaining >= 4, r.peekU8() == 0, r.peekU8(at: 1) == 2 {
                    _ = try r.u16()
                    return File(swatches: try readSection(&r, named: true), hasNames: true)
                }
                return File(swatches: v1, hasNames: false)
            case 2:
                return File(swatches: try readSection(&r, named: true), hasNames: true)
            default:
                throw PSDError.unsupportedVersion(v)
            }
        }
    }

    /// A version 1 section followed by a version 2 section with names, as Photoshop writes.
    public static func write(_ swatches: [Swatch]) throws -> Data {
        guard swatches.count <= maxSwatches else { throw PSDError.limitExceeded("an .aco file holds at most 65535 swatches") }
        var w = ByteWriter()
        for version: UInt16 in [1, 2] {
            w.u16(version)
            w.u16(UInt16(swatches.count))
            for s in swatches {
                let (space, v) = s.color.record
                w.u16(space)
                for x in v { w.u16(x) }
                if version == 2 {
                    let units = utf16Units(s.name, max: maxNameUnits)
                    w.u32(UInt32(units.count + 1))
                    for u in units { w.u16(u) }
                    w.u16(0)
                }
            }
        }
        return w.data
    }
}

// MARK: - .ase

public enum PSDAse {
    public static let maxSwatches = 100_000
    public static let maxNameUnits = 1024
    static let groupStart: UInt16 = 0xC001
    static let groupEnd: UInt16 = 0xC002
    static let colorBlock: UInt16 = 0x0001

    public enum Color: Hashable, Sendable {
        case rgb(Float, Float, Float)
        case cmyk(Float, Float, Float, Float)
        /// L/100 (0...1), a, b.
        case lab(Float, Float, Float)
        /// 1 = white.
        case gray(Float)
        /// Unknown model kept verbatim.
        case other(model: FourCC, data: [UInt8])
    }

    public enum Kind: UInt16, Hashable, Sendable {
        case global = 0, spot = 1, process = 2
    }

    public struct Swatch: Hashable, Sendable {
        public var name: String
        public var color: Color
        public var kind: Kind
        public init(name: String, color: Color, kind: Kind = .process) {
            self.name = name
            self.color = color
            self.kind = kind
        }
    }

    public enum Entry: Hashable, Sendable {
        case swatch(Swatch)
        case group(name: String, swatches: [Swatch])
    }

    public struct File: Hashable, Sendable {
        public var entries: [Entry]
        public init(entries: [Entry]) { self.entries = entries }

        public var swatchCount: Int {
            entries.reduce(0) {
                switch $1 {
                case .swatch: $0 + 1
                case let .group(_, s): $0 + s.count
                }
            }
        }
    }

    static func f32(_ r: inout ByteReader) throws -> Float {
        let v = try r.f32()
        return v.isFinite ? v : 0
    }

    static func readName(_ r: inout ByteReader) throws -> String {
        if r.isAtEnd { return "" }
        let n = Int(try r.u16())
        try r.checkCount(UInt64(n), minItemSize: 2)
        var units: [UInt16] = []
        for _ in 0 ..< n {
            let u = try r.u16()
            if units.count < maxNameUnits { units.append(u) }
        }
        while units.last == 0 { units.removeLast() }
        return String(decoding: units, as: UTF16.self)
    }

    static func readColor(_ b: inout ByteReader) throws -> Swatch {
        let name = try readName(&b)
        let model = try b.fourCC()
        let color: Color
        switch model {
        case "RGB ": color = .rgb(try f32(&b), try f32(&b), try f32(&b))
        case "CMYK": color = .cmyk(try f32(&b), try f32(&b), try f32(&b), try f32(&b))
        case "LAB ": color = .lab(try f32(&b), try f32(&b), try f32(&b))
        case "Gray": color = .gray(try f32(&b))
        default: color = .other(model: model, data: try b.bytes(max(0, b.remaining - 2)))
        }
        let kind = b.remaining >= 2 ? Kind(rawValue: try b.u16()) ?? .process : .process
        return Swatch(name: name, color: color, kind: kind)
    }

    /// Parses an `.ase` file. Unknown block types are skipped, a group end without a start is
    /// ignored and an open group is closed at the end.
    public static func parse(_ data: Data) throws -> File {
        try data.withByteReader { r in
            let sig = try r.fourCC()
            guard sig == "ASEF" else { throw PSDError.invalidSignature(expected: "ASEF", found: sig) }
            let major = try r.u16()
            _ = try r.u16()
            guard major == 1 else { throw PSDError.unsupportedVersion(major) }
            let count = UInt64(try r.u32())
            try r.checkCount(count, minItemSize: 6)
            var entries: [Entry] = []
            var open: (String, [Swatch])?
            var total = 0
            for _ in 0 ..< count {
                let kind = try r.u16()
                var body = try r.sub(Int(try r.u32()))
                switch kind {
                case groupStart:
                    if let (n, s) = open { entries.append(.group(name: n, swatches: s)) }
                    open = (try readName(&body), [])
                case groupEnd:
                    if let (n, s) = open { entries.append(.group(name: n, swatches: s)) }
                    open = nil
                case colorBlock:
                    total += 1
                    guard total <= maxSwatches else { throw PSDError.limitExceeded("too many swatches in an .ase file") }
                    let s = try readColor(&body)
                    if open != nil { open!.1.append(s) } else { entries.append(.swatch(s)) }
                default:
                    break
                }
            }
            if let (n, s) = open { entries.append(.group(name: n, swatches: s)) }
            return File(entries: entries)
        }
    }

    static func putName(_ w: inout ByteWriter, _ name: String) {
        let units = utf16Units(name, max: maxNameUnits)
        w.u16(UInt16(units.count + 1))
        for u in units { w.u16(u) }
        w.u16(0)
    }

    static func putBlock(_ w: inout ByteWriter, _ kind: UInt16, _ body: [UInt8]) {
        w.u16(kind)
        w.u32(UInt32(body.count))
        w.put(body)
    }

    static func putColor(_ w: inout ByteWriter, _ s: Swatch) {
        var b = ByteWriter()
        putName(&b, s.name)
        switch s.color {
        case let .rgb(r, g, bl): b.fourCC("RGB "); b.f32(r); b.f32(g); b.f32(bl)
        case let .cmyk(c, m, y, k): b.fourCC("CMYK"); b.f32(c); b.f32(m); b.f32(y); b.f32(k)
        case let .lab(l, a, bb): b.fourCC("LAB "); b.f32(l); b.f32(a); b.f32(bb)
        case let .gray(g): b.fourCC("Gray"); b.f32(g)
        case let .other(model, data): b.fourCC(model); b.put(data)
        }
        b.u16(s.kind.rawValue)
        putBlock(&w, colorBlock, b.bytes)
    }

    /// Writes version 1.0.
    public static func write(_ file: File) throws -> Data {
        guard file.swatchCount <= maxSwatches else { throw PSDError.limitExceeded("too many swatches for an .ase file") }
        var body = ByteWriter()
        var blocks = 0
        for e in file.entries {
            switch e {
            case let .swatch(s):
                putColor(&body, s)
                blocks += 1
            case let .group(name, swatches):
                var g = ByteWriter()
                putName(&g, name)
                putBlock(&body, groupStart, g.bytes)
                for s in swatches { putColor(&body, s) }
                putBlock(&body, groupEnd, [])
                blocks += 2 + swatches.count
            }
        }
        var w = ByteWriter()
        w.fourCC("ASEF"); w.u16(1); w.u16(0); w.u32(UInt32(blocks))
        w.put(body.bytes)
        return w.data
    }
}
