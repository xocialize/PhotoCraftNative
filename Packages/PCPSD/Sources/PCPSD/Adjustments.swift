// Adjustment layer blocks: brit levl curv hue2 blnc selc mixr phfl expA post thrs nvrt grdm (binary)
// and vibA blwh clrL CgEd (descriptor based).
// Format knowledge ported from photocraft-io (crates/io/src/adjust_map.rs: parse_any, parse_curves,
// levels_rec, parse_gradient_map, write_gradient_map, parse_selective, parse_color_balance,
// parse_photo_filter, parse_channel_mixer, the descriptor readers), MIT OR Apache-2.0, © ArtCraft
// Team and the PhotoCraft contributors; field tables from Adobe's specification (Additional File
// Formats: Levels, Curves, Hue/Saturation, Selective Color; Adjustment layer keys). Levels and Hue
// layout cross-checked against Compositor IO/PSD/PSDReader.swift (MIT, © 2026 Wonder Assembly LLC;
// no code copied).
//
// Every parser keeps the bytes it does not model (`tail`) so `serialized()` reproduces the block
// exactly; the doc-level meaning (curves → LUTs, etc.) stays in the engine.

import Foundation

/// A typed adjustment layer block.
public enum PSDAdjustment: Equatable, Sendable {
    case brightnessContrast(PSDBrightnessContrast)
    case levels(PSDLevels)
    case curves(PSDCurves)
    case hueSaturation(PSDHueSaturation)
    case colorBalance(PSDColorBalance)
    case selectiveColor(PSDSelectiveColor)
    case channelMixer(PSDChannelMixer)
    case photoFilter(PSDPhotoFilter)
    case exposure(PSDExposure)
    case posterize(levels: UInt16, tail: Data)
    case threshold(level: UInt16, tail: Data)
    case invert
    case gradientMap(PSDGradientMap)
    /// `vibA`, `blwh` (versioned descriptor), `clrL` (u16 version + versioned descriptor); `tail`
    /// keeps the padding Photoshop appends.
    case descriptor(key: FourCC, version: UInt16?, PSDVersionedDescriptor, tail: Data)

    public static let keys: [FourCC] = ["levl", "curv", "hue2", "hue ", "brit", "nvrt", "thrs", "post", "expA", "vibA", "blnc", "mixr",
                                        "grdm", "phfl", "selc", "blwh", "clrL"]

    public static func parse(key: FourCC, data: Data) throws -> PSDAdjustment? {
        switch key {
        case "brit": return .brightnessContrast(try PSDBrightnessContrast(bytes: data))
        case "levl": return .levels(try PSDLevels(bytes: data))
        case "curv": return .curves(try PSDCurves(bytes: data))
        case "hue2", "hue ": return .hueSaturation(try PSDHueSaturation(bytes: data))
        case "blnc": return .colorBalance(try PSDColorBalance(bytes: data))
        case "selc": return .selectiveColor(try PSDSelectiveColor(bytes: data))
        case "mixr": return .channelMixer(try PSDChannelMixer(bytes: data))
        case "phfl": return .photoFilter(try PSDPhotoFilter(bytes: data))
        case "expA": return .exposure(try PSDExposure(bytes: data))
        case "post": return try data.withByteReader { r in .posterize(levels: try r.u16(), tail: try r.data(r.remaining)) }
        case "thrs": return try data.withByteReader { r in .threshold(level: try r.u16(), tail: try r.data(r.remaining)) }
        case "nvrt": return .invert
        case "grdm": return .gradientMap(try PSDGradientMap(bytes: data))
        case "vibA", "blwh":
            return try data.withByteReader { r in .descriptor(key: key, version: nil, try PSDVersionedDescriptor.read(&r), tail: try r.data(r.remaining)) }
        case "clrL":
            return try data.withByteReader { r in
                let v = try r.u16()
                return .descriptor(key: key, version: v, try PSDVersionedDescriptor.read(&r), tail: try r.data(r.remaining))
            }
        default: return nil
        }
    }

    public func serialized() -> Data {
        switch self {
        case let .brightnessContrast(v): v.serialized()
        case let .levels(v): v.serialized()
        case let .curves(v): v.serialized()
        case let .hueSaturation(v): v.serialized()
        case let .colorBalance(v): v.serialized()
        case let .selectiveColor(v): v.serialized()
        case let .channelMixer(v): v.serialized()
        case let .photoFilter(v): v.serialized()
        case let .exposure(v): v.serialized()
        case let .posterize(levels, tail), let .threshold(levels, tail):
            { var w = ByteWriter(); w.u16(levels); w.put(tail); return w.data }()
        case .invert: Data()
        case let .gradientMap(v): v.serialized()
        case let .descriptor(_, version, d, tail):
            { var w = ByteWriter(); if let version { w.u16(version) }; d.write(&w); w.put(tail); return w.data }()
        }
    }

    /// A layer block for this adjustment, its data zero-padded to a multiple of 4 inside the
    /// length as Photoshop writes. Photoshop 27.11 requires it for `grdm`: its own gradient map
    /// stores 162 bytes as 164. `serialized()` stays lossless (a parse keeps that padding in the
    /// tail). Wrap its output with `PSDTaggedBlock.fourAligned` or use this.
    public func taggedBlock(key: FourCC) -> PSDTaggedBlock { .fourAligned(key: key, data: serialized()) }
}

extension PSDLayerRecord {
    /// The adjustment this layer applies, when it is an adjustment layer.
    public var adjustment: (key: FourCC, value: PSDAdjustment)? {
        for b in blocks where PSDAdjustment.keys.contains(b.key) {
            if let a = try? PSDAdjustment.parse(key: b.key, data: b.data) { return (b.key, a) }
        }
        return nil
    }
}

public struct PSDBrightnessContrast: Equatable, Sendable {
    public var brightness: Int16
    public var contrast: Int16
    public var mean: UInt16
    public var labOnly: UInt8
    public var tail: Data

    public init(brightness: Int16, contrast: Int16, mean: UInt16 = 127, labOnly: UInt8 = 0) {
        self.brightness = brightness
        self.contrast = contrast
        self.mean = mean
        self.labOnly = labOnly
        tail = Data()
    }

    public init(bytes: Data) throws {
        (brightness, contrast, mean, labOnly, tail) = try bytes.withByteReader { r in
            (try r.i16(), try r.i16(), try r.u16(), r.remaining > 0 ? try r.u8() : 0, try r.data(r.remaining))
        }
    }

    public func serialized() -> Data {
        var w = ByteWriter()
        w.i16(brightness); w.i16(contrast); w.u16(mean); w.u8(labOnly); w.put(tail)
        return w.data
    }
}

public struct PSDLevels: Equatable, Sendable {
    public struct Record: Equatable, Sendable {
        public var inputFloor: UInt16
        public var inputCeiling: UInt16
        public var outputFloor: UInt16
        public var outputCeiling: UInt16
        /// Gamma × 100 (10...999).
        public var gamma: UInt16
        public init(inputFloor: UInt16 = 0, inputCeiling: UInt16 = 255, outputFloor: UInt16 = 0, outputCeiling: UInt16 = 255, gamma: UInt16 = 100) {
            self.inputFloor = inputFloor
            self.inputCeiling = inputCeiling
            self.outputFloor = outputFloor
            self.outputCeiling = outputCeiling
            self.gamma = gamma
        }
    }

    /// 2.
    public var version: UInt16
    /// Master first, then one per channel (Photoshop writes 29).
    public var records: [Record]
    /// Bytes after the records (the CS `Lvls` extension and anything else), kept.
    public var tail: Data

    public init(records: [Record]) {
        version = 2
        self.records = records + Array(repeating: Record(), count: max(0, 29 - records.count))
        tail = Data()
    }

    public init(bytes: Data) throws {
        (version, records, tail) = try bytes.withByteReader { r in
            let v = try r.u16()
            var recs: [Record] = []
            while recs.count < 29, r.remaining >= 10 {
                recs.append(Record(inputFloor: try r.u16(), inputCeiling: try r.u16(), outputFloor: try r.u16(), outputCeiling: try r.u16(), gamma: try r.u16()))
            }
            return (v, recs, try r.data(r.remaining))
        }
    }

    public func serialized() -> Data {
        var w = ByteWriter()
        w.u16(version)
        for x in records { w.u16(x.inputFloor); w.u16(x.inputCeiling); w.u16(x.outputFloor); w.u16(x.outputCeiling); w.u16(x.gamma) }
        w.put(tail)
        return w.data
    }
}

public struct PSDCurves: Equatable, Sendable {
    public struct Curve: Equatable, Sendable {
        /// Channel index (bit of the bitmap: 0 master/composite, 1... channels).
        public var channel: Int
        /// (input, output) points 0...255 for point curves.
        public var points: [(input: UInt16, output: UInt16)]
        /// 256 output bytes for pencil ("map") curves.
        public var map: [UInt8]?

        public static func == (a: Curve, b: Curve) -> Bool {
            a.channel == b.channel && a.map == b.map && a.points.map(\.input) == b.points.map(\.input) && a.points.map(\.output) == b.points.map(\.output)
        }
    }

    /// Leading byte: non-zero for pencil-drawn (map) curves.
    public var isMap: Bool
    /// 1 or 4.
    public var version: UInt16
    /// Bit n set: a curve for channel n follows.
    public var bitmap: UInt32
    public var curves: [Curve]
    /// The `Crv ` extension (and anything after), kept raw.
    public var tail: Data

    public init(bytes: Data) throws {
        (isMap, version, bitmap, curves, tail) = try bytes.withByteReader { r in
            let map = try r.u8() != 0
            let version = try r.u16()
            guard version == 1 || version == 4 else { throw PSDError.invalid("curves version \(version)") }
            let bits = try r.u32()
            var curves: [Curve] = []
            for bit in 0 ..< 32 where bits & (1 << UInt32(bit)) != 0 {
                if map {
                    curves.append(Curve(channel: bit, points: [], map: try r.bytes(256)))
                } else {
                    let n = try r.u16()
                    try r.checkCount(UInt64(n), minItemSize: 4)
                    let pts = try (0 ..< n).map { _ -> (input: UInt16, output: UInt16) in
                        let out = try r.u16()
                        return (try r.u16(), out)
                    }
                    curves.append(Curve(channel: bit, points: pts, map: nil))
                }
            }
            return (map, version, bits, curves, try r.data(r.remaining))
        }
    }

    public init(curves: [Curve]) {
        isMap = curves.contains { $0.map != nil }
        version = 1
        bitmap = curves.reduce(0) { $0 | 1 << UInt32($1.channel) }
        self.curves = curves.sorted { $0.channel < $1.channel }
        tail = Data()
    }

    public func serialized() -> Data {
        var w = ByteWriter()
        w.u8(isMap ? 1 : 0)
        w.u16(version)
        w.u32(bitmap)
        for c in curves {
            if let m = c.map {
                w.put(Array((m + [UInt8](repeating: 0, count: 256)).prefix(256)))
            } else {
                w.u16(UInt16(c.points.count))
                for p in c.points { w.u16(p.output); w.u16(p.input) }
            }
        }
        w.put(tail)
        return w.data
    }
}

public struct PSDHueSaturation: Equatable, Sendable {
    public struct Range: Equatable, Sendable {
        /// Begin ramp, begin full, end full, end ramp (degrees).
        public var bounds: [Int16]
        public var hue: Int16
        public var saturation: Int16
        public var lightness: Int16
    }

    public var version: UInt16
    public var colorize: Bool
    public var padding: UInt8
    /// Colorize hue, saturation, lightness.
    public var colorization: [Int16]
    /// Master hue, saturation, lightness.
    public var master: [Int16]
    /// Reds, yellows, greens, cyans, blues, magentas.
    public var ranges: [Range]
    public var tail: Data

    public init(bytes: Data) throws {
        (version, colorize, padding, colorization, master, ranges, tail) = try bytes.withByteReader { r in
            let v = try r.u16()
            let c = try r.u8() != 0
            let p = try r.u8()
            let col = try (0 ..< 3).map { _ in try r.i16() }
            let m = try (0 ..< 3).map { _ in try r.i16() }
            var ranges: [Range] = []
            while ranges.count < 6, r.remaining >= 14 {
                ranges.append(Range(bounds: try (0 ..< 4).map { _ in try r.i16() }, hue: try r.i16(), saturation: try r.i16(), lightness: try r.i16()))
            }
            return (v, c, p, col, m, ranges, try r.data(r.remaining))
        }
    }

    public func serialized() -> Data {
        var w = ByteWriter()
        w.u16(version); w.u8(colorize ? 1 : 0); w.u8(padding)
        for x in colorization + master { w.i16(x) }
        for rg in ranges {
            for b in rg.bounds { w.i16(b) }
            w.i16(rg.hue); w.i16(rg.saturation); w.i16(rg.lightness)
        }
        w.put(tail)
        return w.data
    }
}

public struct PSDColorBalance: Equatable, Sendable {
    /// Cyan-red, magenta-green, yellow-blue (−100...100) for shadows, midtones, highlights.
    public var shadows: [Int16]
    public var midtones: [Int16]
    public var highlights: [Int16]
    public var preserveLuminosity: Bool
    public var tail: Data

    public init(bytes: Data) throws {
        (shadows, midtones, highlights, preserveLuminosity, tail) = try bytes.withByteReader { r in
            let s = try (0 ..< 3).map { _ in try r.i16() }, m = try (0 ..< 3).map { _ in try r.i16() }, h = try (0 ..< 3).map { _ in try r.i16() }
            return (s, m, h, try r.u8() != 0, try r.data(r.remaining))
        }
    }

    public func serialized() -> Data {
        var w = ByteWriter()
        for x in shadows + midtones + highlights { w.i16(x) }
        w.u8(preserveLuminosity ? 1 : 0)
        w.put(tail)
        return w.data
    }
}

public struct PSDSelectiveColor: Equatable, Sendable {
    public var version: UInt16
    /// 0 relative, 1 absolute.
    public var method: UInt16
    /// Ten CMYK records (−100...100); record 0 is reserved, 1...9 are reds … blacks.
    public var records: [[Int16]]
    public var tail: Data

    public init(bytes: Data) throws {
        (version, method, records, tail) = try bytes.withByteReader { r in
            let v = try r.u16(), m = try r.u16()
            var recs: [[Int16]] = []
            while recs.count < 10, r.remaining >= 8 { recs.append(try (0 ..< 4).map { _ in try r.i16() }) }
            return (v, m, recs, try r.data(r.remaining))
        }
    }

    public func serialized() -> Data {
        var w = ByteWriter()
        w.u16(version); w.u16(method)
        for rec in records { for x in rec { w.i16(x) } }
        w.put(tail)
        return w.data
    }
}

public struct PSDChannelMixer: Equatable, Sendable {
    public var version: UInt16
    public var monochrome: Bool
    /// Per output channel: four source percentages (R, G, B, and K for CMYK) and a constant.
    public var records: [[Int16]]
    public var tail: Data

    public init(bytes: Data) throws {
        (version, monochrome, records, tail) = try bytes.withByteReader { r in
            let v = try r.u16(), m = try r.u16() != 0
            var recs: [[Int16]] = []
            while r.remaining >= 10 { recs.append(try (0 ..< 5).map { _ in try r.i16() }) }
            return (v, m, recs, try r.data(r.remaining))
        }
    }

    public func serialized() -> Data {
        var w = ByteWriter()
        w.u16(version); w.u16(monochrome ? 1 : 0)
        for rec in records { for x in rec { w.i16(x) } }
        w.put(tail)
        return w.data
    }
}

public struct PSDPhotoFilter: Equatable, Sendable {
    /// 2 (colour record) or 3 (XYZ).
    public var version: UInt16
    /// Version 3: X, Y, Z (photocraft reads 1.0 = 32768, inferred).
    public var xyz: [UInt32]?
    /// Version 2.
    public var color: PSDColorRecord?
    /// Percent.
    public var density: UInt32
    public var preserveLuminosity: Bool
    public var tail: Data

    public init(bytes: Data) throws {
        (version, xyz, color, density, preserveLuminosity, tail) = try bytes.withByteReader { r in
            let v = try r.u16()
            var xyz: [UInt32]?
            var color: PSDColorRecord?
            if v == 3 { xyz = try (0 ..< 3).map { _ in try r.u32() } } else { color = try .read(&r) }
            return (v, xyz, color, try r.u32(), try r.u8() != 0, try r.data(r.remaining))
        }
    }

    public func serialized() -> Data {
        var w = ByteWriter()
        w.u16(version)
        if let xyz { for x in xyz { w.u32(x) } } else { (color ?? PSDColorRecord(space: 0, components: [0, 0, 0, 0])).write(&w) }
        w.u32(density); w.u8(preserveLuminosity ? 1 : 0); w.put(tail)
        return w.data
    }
}

public struct PSDExposure: Equatable, Sendable {
    public var version: UInt16
    public var exposure: Float
    public var offset: Float
    public var gamma: Float
    public var tail: Data

    public init(exposure: Float, offset: Float, gamma: Float) {
        version = 1
        self.exposure = exposure
        self.offset = offset
        self.gamma = gamma
        tail = Data()
    }

    public init(bytes: Data) throws {
        (version, exposure, offset, gamma, tail) = try bytes.withByteReader { r in (try r.u16(), try r.f32(), try r.f32(), try r.f32(), try r.data(r.remaining)) }
    }

    public func serialized() -> Data {
        var w = ByteWriter()
        w.u16(version); w.f32(exposure); w.f32(offset); w.f32(gamma); w.put(tail)
        return w.data
    }
}

/// `grdm` gradient map settings.
public struct PSDGradientMap: Equatable, Sendable {
    public struct ColorStop: Equatable, Sendable {
        /// 0...4096.
        public var location: UInt32
        /// Percent.
        public var midpoint: UInt32
        public var color: PSDColorRecord
        public var padding: UInt16
    }

    public struct OpacityStop: Equatable, Sendable {
        public var location: UInt32
        public var midpoint: UInt32
        /// 0...255.
        public var opacity: UInt16
    }

    /// 1, or 3 with an interpolation method key.
    public var version: UInt16
    public var reverse: Bool
    public var dither: Bool
    /// Version 3: `Gcls` classic, `Perc` perceptual, `Lnr ` linear, `Smoo` smooth.
    public var method: FourCC?
    public var name: PSDUnicodeString
    public var colorStops: [ColorStop]
    public var opacityStops: [OpacityStop]
    /// Expansion count, smoothness (/4096), length, mode, seed, show transparency, vector colour,
    /// roughness, colour model, min ×4, max ×4, dummy — and anything else — kept raw.
    public var noiseAndTail: Data

    public init(bytes: Data) throws {
        self = try bytes.withByteReader { r in
            let v = try r.u16()
            let reverse = try r.u8() != 0, dither = try r.u8() != 0
            var method: FourCC?
            if v == 3 { method = try r.fourCC() } else if v != 1 { throw PSDError.invalid("gradient map version \(v)") }
            let name = PSDUnicodeString(units: try r.unicodeUnits())
            let nc = try r.u16()
            try r.checkCount(UInt64(nc), minItemSize: 20)
            let cs = try (0 ..< nc).map { _ in ColorStop(location: try r.u32(), midpoint: try r.u32(), color: try .read(&r), padding: try r.u16()) }
            let nt = try r.u16()
            try r.checkCount(UInt64(nt), minItemSize: 10)
            let ts = try (0 ..< nt).map { _ in OpacityStop(location: try r.u32(), midpoint: try r.u32(), opacity: try r.u16()) }
            return PSDGradientMap(version: v, reverse: reverse, dither: dither, method: method, name: name, colorStops: cs, opacityStops: ts,
                                  noiseAndTail: try r.data(r.remaining))
        }
    }

    init(version: UInt16, reverse: Bool, dither: Bool, method: FourCC?, name: PSDUnicodeString, colorStops: [ColorStop], opacityStops: [OpacityStop], noiseAndTail: Data) {
        self.version = version
        self.reverse = reverse
        self.dither = dither
        self.method = method
        self.name = name
        self.colorStops = colorStops
        self.opacityStops = opacityStops
        self.noiseAndTail = noiseAndTail
    }

    /// Smoothness 0...1 (the u16 after the expansion count).
    public var smoothness: Double? {
        guard noiseAndTail.count >= 4 else { return nil }
        return try? noiseAndTail.withByteReader { r in _ = try r.u16(); return Double(try r.u16()) / 4096 }
    }

    public func serialized() -> Data {
        var w = ByteWriter()
        w.u16(version); w.u8(reverse ? 1 : 0); w.u8(dither ? 1 : 0)
        if version == 3 { w.fourCC(method ?? "Gcls") }
        name.write(&w)
        w.u16(UInt16(colorStops.count))
        for s in colorStops { w.u32(s.location); w.u32(s.midpoint); s.color.write(&w); w.u16(s.padding) }
        w.u16(UInt16(opacityStops.count))
        for s in opacityStops { w.u32(s.location); w.u32(s.midpoint); w.u16(s.opacity) }
        w.put(noiseAndTail)
        return w.data
    }
}
