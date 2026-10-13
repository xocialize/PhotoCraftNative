// Mapping between PSD adjustment-layer blocks and `Adjustment`.
// Port of photocraft-io (crates/io/src/adjust_map.rs, and the colour-structure decoding of
// channel_map.rs it uses: `decode_known_color`, `hsb_to_rgb`), MIT OR Apache-2.0, © ArtCraft Team
// and the PhotoCraft contributors.
//
// Binary layouts follow the Adobe spec ("Adjustment layer" section). The mapped subset keeps the
// master/composite parameters; other channels of Levels/Curves/Hue-Sat are written back with
// defaults.
//
// Every `Adjustment` kind is written (`vibA`, `blnc`, `blwh`, `phfl` and `mixr` included); a Color
// Lookup without a table is written as an identity cube and a Gradient Map with fewer than two stops
// as the equivalent two-stop gradient, so nothing is dropped on save. Blocks that cannot be read
// (noise gradients, profile lookups, CMYK channel mixers, unknown versions) stay
// `Adjustment.unsupported` and are written back verbatim.
//
// The PSD exporter keeps an imported block only while `parse` of it equals the layer's current
// `Adjustment`, so `parse` is deterministic and `write` round-trips.

import Foundation
import PCDocument
import PCFoundation
import PCIOCore
import PCPSD

public enum AdjustMap {
    /// All PSD adjustment keys recognized as adjustment layers (photocraft `ADJUSTMENT_KEYS`).
    public static let adjustmentKeys: [FourCC] =
        ["levl", "curv", "hue2", "brit", "nvrt", "thrs", "post", "expA", "vibA", "blnc", "mixr", "grdm", "phfl", "selc", "blwh", "clrL"]

    /// Channel interpretation of per-channel Levels/Curves records.
    public enum Channels: Sendable, Hashable {
        /// Records 1...3 are R, G, B.
        case rgb
        /// Record 1 is the gray channel (applied to all three display channels).
        case gray
        /// Records 1...4 are cyan, magenta, yellow, black (`ToneSpace.cmyk`).
        case cmyk
        /// Records 1...3 are lightness, a, b (`ToneSpace.lab`).
        case lab
        /// Channel records do not map to display channels (multichannel, indexed…); ignored.
        case other
    }

    /// Whether Photoshop offers the adjustment `key` in a document of `mode` at `depth` (the mode
    /// and depth the file is written in). Photoshop 27.11 refuses to make the others there
    /// ("Could not complete the command because that content type is not supported for this color
    /// mode": the ps-corpus builder's notes for `adj-stack-cmyk-8`, `-lab-8`, `-gray-16`,
    /// `-rgb-32`), and opens such a layer from a file as an empty pixel layer. Photoshop oracle C′,
    /// 1,826 adjustment layers in the files it opened: all 224 of these kinds came back as pixel
    /// layers, and every other one as an adjustment except Color Lookups written with a table
    /// (29, see `write`) and one truncated Levels block (a fixture damaged on purpose).
    /// Grayscale 32-bit takes both lists (measured: Hue/Saturation, Invert, Posterize, Threshold,
    /// Gradient Map). Unknown keys are offered.
    public static func photoshopOffers(_ key: FourCC, mode: ColorMode, depth: SampleType) -> Bool {
        let k = key == "hue " ? "hue2" : key
        var missing: Set<FourCC> = []
        switch mode {
        case .cmyk: missing = ["blwh", "expA", "vibA"]
        case .grayscale: missing = ["hue2", "blnc", "blwh", "mixr", "phfl", "selc", "vibA", "clrL"]
        case .lab: missing = ["blwh", "mixr", "expA", "selc", "vibA"]
        default: break
        }
        let notIn32Bit: [FourCC] = ["grdm", "nvrt", "post", "thrs", "vibA"]
        if depth == .f32 { missing.formUnion(notIn32Bit) }
        return !missing.contains(k)
    }

    /// The PSD key `a` is written under (nil when it writes nothing).
    public static func psdKey(_ a: Adjustment) -> FourCC? {
        if case let .unsupported(k, _) = a { return FourCC(bytes: Array(k.utf8)) }
        return write(a).first?.key
    }

    /// Photoshop's own block for a Color Lookup layer with no table chosen (ps-corpus
    /// `adj-colorLookup.psd` and every adjustment stack): version 1 and an empty descriptor whose
    /// name is one NUL. Photoshop opens it as a Color Lookup layer; the identity cube PCIO wrote
    /// before was opened as a pixel layer.
    public static let photoshopEmptyLookup: [UInt8] = [0, 1, 0, 0, 0, 16, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0x6E, 0x75, 0x6C, 0x6C, 0, 0, 0, 0]

    /// The menu name of the adjustment a PSD key holds (for messages).
    public static func label(_ key: FourCC) -> String {
        switch key {
        case "levl": "Levels"
        case "curv": "Curves"
        case "hue2": "Hue/Saturation"
        case "brit": "Brightness/Contrast"
        case "nvrt": "Invert"
        case "thrs": "Threshold"
        case "post": "Posterize"
        case "expA": "Exposure"
        case "vibA": "Vibrance"
        case "blnc": "Color Balance"
        case "mixr": "Channel Mixer"
        case "grdm": "Gradient Map"
        case "phfl": "Photo Filter"
        case "selc": "Selective Color"
        case "blwh": "Black & White"
        case "clrL": "Color Lookup"
        default: "adjustment"
        }
    }

    /// Why `parse` keeps a block as `Adjustment.unsupported`, when there is more to say than "it
    /// could not be read" (so far: Color Lookup).
    public static func unreadableReason(_ key: FourCC, _ data: [UInt8]) -> String? {
        switch key {
        case "clrL":
            if case let .failure(e) = readLookup(data) { return e.message }
            return nil
        default:
            return nil
        }
    }

    /// Parses an adjustment block. `cged` is the optional `CgEd` block data (modern
    /// brightness/contrast parameters). Levels/Curves store the composite record first, then one per
    /// document channel (see `Channels`).
    public static func parse(_ key: FourCC, _ data: [UInt8], _ cged: [UInt8]?, _ channels: Channels) -> Adjustment {
        // A CMYK Channel Mixer (any record using the fourth, black, source) has no RGB meaning: keep
        // it raw. Mixers written by `write` leave that source at 0 and map in every mode.
        if key == "mixr", channels == .cmyk || channels == .other {
            var r = 0
            while let k = bei16(data, 4 + r * 10 + 6) {
                if k != 0 { return unsupported(key, data) }
                r += 1
            }
        }
        var a = parseAny(key, data, cged)
        switch a {
        case var .levels(l):
            switch channels {
            case .cmyk: l.space = .cmyk
            case .lab: l.space = .lab; l.black = LevelsChannel()
            default: l.black = LevelsChannel()
            }
            switch channels {
            case .gray: l.perChannel = Array(repeating: l.perChannel[0], count: 3)
            case .other: l.perChannel = Array(repeating: LevelsChannel(), count: 3)
            default: break
            }
            a = .levels(l)
        case var .curves(c):
            switch channels {
            case .cmyk:
                c.space = .cmyk
                if isIdentityCurve(c.black) { c.black = [] }
            case .lab:
                c.space = .lab
                c.black = []
            default:
                c.black = []
            }
            switch channels {
            case .gray: c.perChannel = Array(repeating: c.perChannel[0], count: 3)
            case .other: c.perChannel = Array(repeating: identityLine, count: 3)
            default: break
            }
            a = .curves(c)
        default:
            break
        }
        return a
    }

    /// Points an imported `grdm` block at `target` when only Reverse and/or Dither differ (the stops
    /// parse unchanged): patches those two bytes and returns `true`, so the file's own stops (in
    /// whatever colour space it stored them), smoothness and method survive the save. `false`
    /// leaves `data` untouched.
    public static func retargetGradientMap(_ data: inout [UInt8], _ target: Adjustment, _ channels: Channels) -> Bool {
        guard case let .gradientMap(t) = target else { return false }
        guard case let .gradientMap(parsed) = parse("grdm", data, nil, channels), parsed.stops == t.stops, data.count >= 4 else { return false }
        data[2] = t.reverse ? 1 : 0
        data[3] = t.dither ? 1 : 0
        return true
    }

    /// Serializes an adjustment into its PSD blocks: `(key, data)` pairs (Brightness/Contrast also
    /// writes a `CgEd` descriptor). Every evaluated kind has an encoding; the result is empty only
    /// for an `Adjustment.unsupported` with a malformed key.
    public static func write(_ adj: Adjustment) -> RawBlocks {
        var v = BEWriter()
        switch adj {
        case .invert:
            return [("nvrt", [])]
        case let .threshold(level):
            v.u16(max(q255(level), 1))
            v.u16(0)
            return [("thrs", v.bytes)]
        case let .posterize(levels):
            v.u16(UInt16(min(max(levels, 2), 255)))
            v.u16(0)
            return [("post", v.bytes)]
        case let .brightnessContrast(b):
            v.i16(clampI16(b.brightness))
            v.i16(clampI16(b.contrast))
            v.u16(127)
            v.u8(0)
            // Photoshop 27.11's layouts (PCRender phase 5: M2 PSDs, ps-corpus adj-brightnessContrast*):
            // Light adds `brightnessExposure` and the four tone keys and `brightnessMode`; an explicit
            // Modern adds `brightnessMode` after `Lab `; legacy keeps the pre-27 form (no mode key,
            // `useLegacy` true), which Photoshop reads as Legacy.
            var d = PSDDescriptor(classID: "null").with("Vrsn", .integer(1))
            if b.mode == .light { d = d.with("brightnessExposure", .double(Double(b.exposure))) }
            d = d.with("Brgh", .integer(roundCast(b.brightness)))  // Light ignores it; Photoshop's own Light layers store 0
                .with("Cntr", .integer(roundCast(b.contrast)))
            if b.mode == .light {
                d = d.with("brightnessWhites", .integer(roundCast(b.whites)))
                    .with("brightnessBlacks", .integer(roundCast(b.blacks)))
                    .with("brightnessHighlights", .integer(roundCast(b.highlights)))
                    .with("brightnessShadows", .integer(roundCast(b.shadows)))
            }
            d = d.with("means", .integer(127)).with("Lab ", .boolean(false))
            switch b.mode {
            case .light: d = d.with("brightnessMode", Blocks.enumValue("brightnessModeType", "brightnessModeLight"))
            case .modern: d = d.with("brightnessMode", Blocks.enumValue("brightnessModeType", "brightnessModeModern"))
            case .legacy: break
            }
            d = d.with("useLegacy", .boolean(b.legacy)).with("Auto", .boolean(false))
            return [("brit", v.bytes), ("CgEd", Blocks.versionedBytes(d))]
        case let .hueSaturation(h):
            v.u16(2)
            v.u8(h.colorize ? 1 : 0)
            v.u8(0)
            for _ in 0 ..< 2 {
                for x in [h.hue, h.saturation, h.lightness] { v.i16(clampI16(x)) }
            }
            // Six hue ranges (reds, yellows, greens, cyans, blues, magentas): range values in
            // 0..<360, then the range's hue, saturation and lightness.
            for i in 0 ..< 6 {
                let r = i < h.ranges.count ? h.ranges[i] : HueRange.neutral(i)
                for k in 0 ..< 4 {
                    let deg: UInt16 = roundCast(remEuclid(r.bounds[k], 360))
                    v.u16(deg % 360)
                }
                for x in [r.hue, r.saturation, r.lightness] { v.i16(clampI16(x)) }
            }
            return [("hue2", v.bytes)]
        case let .exposure(e):
            v.u16(1)
            for x in [e.exposure, e.offset, e.gamma] { v.f32(x) }
            v.u8(1) // colour space flag (spec: "1 byte")
            return [("expA", v.bytes)]
        case let .levels(l):
            v.u16(2)
            levelsWrite(&v, l.master)
            for i in 0 ..< 3 { levelsWrite(&v, i < l.perChannel.count ? l.perChannel[i] : LevelsChannel()) }
            levelsWrite(&v, l.space == .cmyk ? l.black : LevelsChannel())
            for _ in 5 ..< 29 { levelsWrite(&v, LevelsChannel()) }
            return [("levl", v.bytes)]
        case let .curves(c):
            v.u8(c.pencil ? 1 : 0)
            v.u16(1)
            let ink = c.space == .cmyk && c.black.count >= 2
            v.u32(ink ? 0b11111 : 0b1111)
            var all = [c.master] + (0 ..< 3).map { $0 < c.perChannel.count ? c.perChannel[$0] : identityLine }
            if ink { all.append(c.black) }
            for curve in all {
                if c.pencil {
                    v.put(curveMapOutputs(curve).map { UInt8(clamping: q255($0)) })
                    continue
                }
                v.u16(UInt16(min(curve.count, 19)))
                for p in curve.prefix(19) {
                    v.u16(q255(p.output))
                    v.u16(q255(p.input))
                }
            }
            return [("curv", v.bytes)]
        case let .selectiveColor(s):
            v.u16(1)
            v.u16(s.relative ? 0 : 1)
            v.zeros(8)
            for r in 0 ..< 9 {
                let rec = r < s.adjustments.count ? s.adjustments[r] : .zero
                for k in 0 ..< 4 { v.i16(clampI16(clampf(rec[k], -100, 100))) }
            }
            return [("selc", v.bytes)]
        case let .colorLookup(c):
            // A lookup without a usable table (none chosen yet, or a bad size) renders as the
            // identity: written as Photoshop writes a Color Lookup with no table chosen.
            let n = Int(c.size)
            guard let table = c.lut, let len = lut3DLength(c.size), len <= table.count, n <= 256 else {
                return [("clrL", photoshopEmptyLookup)]
            }
            let file = LutFile(title: "", size: n, data: Array(table[..<len]))
            let dither = c.dither
            let d = PSDDescriptor(classID: "null")
                .with("lookupType", Blocks.enumValue("colorLookupType", "3DLUT"))
                .with("NM  ", Blocks.text(c.name))
                .with("Dthr", .boolean(dither))
                .with("profile", .rawData(Data()))
                .with("LUTFormat", Blocks.enumValue("LUTFormatType", "LUTFormatCUBE"))
                .with("dataOrder", Blocks.enumValue("colorLookupOrder", "rgbOrder"))
                .with("tableOrder", Blocks.enumValue("colorLookupOrder", "bgrOrder"))
                .with("LUT3DFileData", .rawData(Data(LutFile.writeCube(file).utf8)))
                .with("LUT3DFileName", Blocks.text(c.name))
            v.u16(1)
            v.put(Blocks.versionedBytes(d))
            return [("clrL", v.bytes)]
        case let .gradientMap(g):
            // Photoshop needs two stops; fewer are written as the gradient they render as (none:
            // black to white, i.e. the gray value itself; one: that colour throughout).
            let stops: [GradientMapStop]
            switch g.stops.count {
            case 0: stops = [GradientMapStop(0, .zero), GradientMapStop(1, .one)]
            case 1: stops = [GradientMapStop(0, g.stops[0].rgb), GradientMapStop(1, g.stops[0].rgb)]
            default: stops = g.stops
            }
            return [("grdm", writeGradientMap(stops, g.reverse, g.dither))]
        case let .vibrance(x):
            let d = PSDDescriptor(classID: "null")
                .with("vibrance", .integer(Int32(clampI16(clampf(x.vibrance, -100, 100)))))
                .with("Strt", .integer(Int32(clampI16(clampf(x.saturation, -100, 100)))))
            return [("vibA", Blocks.versionedBytes(d))]
        case let .colorBalance(b):
            for t in [b.shadows, b.midtones, b.highlights] {
                for k in 0 ..< 3 { v.i16(clampI16(clampf(t[k], -100, 100))) }
            }
            v.u8(b.preserveLuminosity ? 1 : 0)
            v.u8(0)
            return [("blnc", v.bytes)]
        case let .blackWhite(b):
            var d = PSDDescriptor(classID: "null")
            for (i, k) in bwKeys.enumerated() {
                let w = i < b.weights.count ? b.weights[i] : bwDefault[i]
                d = d.with(k, .integer(Int32(clampI16(clampf(w, -200, 300)))))
            }
            d = d.with("useTint", .boolean(b.tint != nil))
                .with("tintColor", .descriptor(rgbDesc(b.tint ?? bwTint)))
                .with("bwPresetKind", .integer(1))
                .with("blackAndWhitePresetFileName", Blocks.text(""))
            return [("blwh", Blocks.versionedBytes(d))]
        case let .photoFilter(p):
            // Version 2: an RGB colour structure keeps the colour at 16 bits.
            v.u16(2)
            v.u16(0)
            for k in 0 ..< 3 { v.u16(roundCast(clampf(p.color[k], 0, 1) * 65535)) }
            v.u16(0)
            v.u32(roundCast(clampf(p.density, 0, 1) * 100))
            v.u8(p.preserveLuminosity ? 1 : 0)
            // Photoshop requires the 17-byte Photo Filter payload after the version to be padded to
            // a 4-byte boundary INSIDE the tagged block's declared length. A single pad byte made
            // an 18-byte `phfl` block that Photoshop could not open (#1455).
            v.zeros(3)
            return [("phfl", v.bytes)]
        case let .channelMixer(m):
            v.u16(1)
            v.u16(m.monochrome ? 1 : 0)
            // Red, green, blue, then the gray record (the first row, which monochrome uses).
            let rows = (0 ..< 3).map { $0 < m.matrix.count ? m.matrix[$0] : SIMD4<Float>.zero }
            func pct(_ x: Float) -> Int16 { clampI16(clampf(x * 100, -200, 200)) }
            for row in rows + [rows[0]] {
                for k in 0 ..< 3 { v.i16(pct(row[k])) }
                v.zeros(2)
                v.i16(pct(row[3]))
            }
            return [("mixr", v.bytes)]
        case let .unsupported(psdKey, raw):
            let k = Array(psdKey.utf8)
            if k.count == 4 { return [(FourCC(bytes: k), raw)] }
            // Only an `unsupported` block whose key is not four bytes has no encoding.
            return []
        }
    }
}

// MARK: - Parsing

extension AdjustMap {
    private static let identityLine = [CurvePoint(input: 0, output: 0), CurvePoint(input: 1, output: 1)]

    private static func be16(_ d: [UInt8], _ at: Int) -> UInt16? {
        guard at >= 0, at <= d.count - 2 else { return nil }
        return UInt16(d[at]) << 8 | UInt16(d[at + 1])
    }

    private static func bei16(_ d: [UInt8], _ at: Int) -> Int16? { be16(d, at).map { Int16(bitPattern: $0) } }

    private static func be32(_ d: [UInt8], _ at: Int) -> UInt32? {
        guard at >= 0, at <= d.count - 4 else { return nil }
        return UInt32(d[at]) << 24 | UInt32(d[at + 1]) << 16 | UInt32(d[at + 2]) << 8 | UInt32(d[at + 3])
    }

    private static func bef32(_ d: [UInt8], _ at: Int) -> Float? { be32(d, at).map { Float(bitPattern: $0) } }

    private static func byte(_ d: [UInt8], _ at: Int) -> UInt8? { at >= 0 && at < d.count ? d[at] : nil }

    private static func unsupported(_ key: FourCC, _ data: [UInt8]) -> Adjustment {
        .unsupported(psdKey: String(decoding: key.bytes, as: UTF8.self), raw: data)
    }

    private static func levelsRec(_ d: [UInt8], _ at: Int) -> LevelsChannel? {
        guard let ib = be16(d, at), let iw = be16(d, at + 2), let ob = be16(d, at + 4), let ow = be16(d, at + 6), let g = be16(d, at + 8) else { return nil }
        return LevelsChannel(inBlack: Float(ib) / 255, inWhite: Float(iw) / 255, gamma: Float(g) / 100, outBlack: Float(ob) / 255, outWhite: Float(ow) / 255)
    }

    private static func parseCurves(_ d: [UInt8]) -> Adjustment? {
        // map flag(1) version(2) bitmap(4). A map (Photoshop's pencil-drawn curves) stores 256
        // output bytes per channel instead of a point list (psd-tools reads the flag as `is_map`).
        guard let flag = byte(d, 0) else { return nil }
        let pencil = flag != 0
        guard let version = be16(d, 1), version == 1 || version == 4 else { return nil }
        guard let bits = be32(d, 3) else { return nil }
        var at = 7
        var curves = Array(repeating: identityLine, count: 5)
        for bit in 0 ..< 32 where bits & (1 << UInt32(bit)) != 0 {
            if pencil {
                guard at + curveMapLength <= d.count else { return nil }
                let map = d[at ..< at + curveMapLength]
                at += curveMapLength
                if bit < curves.count { curves[bit] = curveMap(map.map { Float($0) / 255 }) }
                continue
            }
            guard let n = be16(d, at) else { return nil }
            at += 2
            var pts: [CurvePoint] = []
            pts.reserveCapacity(min(Int(n), 64))
            for _ in 0 ..< Int(n) {
                guard let out = be16(d, at), let inp = be16(d, at + 2) else { return nil }
                at += 4
                pts.append(CurvePoint(input: Float(inp) / 255, output: Float(out) / 255))
            }
            if bit < curves.count { curves[bit] = pts }
        }
        return .curves(Adjustment.Curves(master: curves[0], perChannel: [curves[1], curves[2], curves[3]], space: .rgb, black: curves[4], pencil: pencil))
    }

    private static func descNum(_ d: PSDDescriptor, _ key: String) -> Float? {
        switch d[key] {
        case let .integer(v)?: Float(v)
        case let .double(v)?: Float(v)
        case let .unitFloat(_, v)?: Float(v)
        default: nil
        }
    }

    private static func descBool(_ d: PSDDescriptor, _ key: String) -> Bool? {
        if case let .boolean(b)? = d[key] { return b }
        return nil
    }

    private static func parseAny(_ key: FourCC, _ data: [UInt8], _ cged: [UInt8]?) -> Adjustment {
        let parsed: Adjustment?
        switch key {
        case "nvrt": parsed = .invert
        case "thrs": parsed = be16(data, 0).map { Adjustment.threshold(level: Float($0) / 255) }
        case "post": parsed = be16(data, 0).map { Adjustment.posterize(levels: UInt32($0)) }
        case "brit":
            var modern: Adjustment?
            if let c = cged, let d = Blocks.parsePrefixVersioned(c), let b = descNum(d, "Brgh"), let k = descNum(d, "Cntr") {
                // `brightnessMode` (Photoshop 27): Legacy / Modern / Light. Without it, `useLegacy`
                // decides between Legacy and Modern, as before.
                let legacy = descBool(d, "useLegacy") ?? false
                var mode: Adjustment.BrightnessContrast.Mode = legacy ? .legacy : .modern
                if case let .enumerated(_, value)? = d["brightnessMode"] {
                    switch value.name {
                    case "brightnessModeLight": mode = .light
                    case "brightnessModeModern": mode = .modern
                    case "brightnessModeLegacy": mode = .legacy
                    default: break
                    }
                }
                modern = .brightnessContrast(Adjustment.BrightnessContrast(
                    brightness: b, contrast: k, mode: mode, exposure: mode == .light ? descNum(d, "brightnessExposure") ?? 0 : 0,
                    whites: mode == .light ? descNum(d, "brightnessWhites") ?? 0 : 0, blacks: mode == .light ? descNum(d, "brightnessBlacks") ?? 0 : 0,
                    highlights: mode == .light ? descNum(d, "brightnessHighlights") ?? 0 : 0,
                    shadows: mode == .light ? descNum(d, "brightnessShadows") ?? 0 : 0))
            }
            if modern == nil, let b = bei16(data, 0), let k = bei16(data, 2) {
                modern = .brightnessContrast(Adjustment.BrightnessContrast(brightness: Float(b), contrast: Float(k), legacy: true))
            }
            parsed = modern
        case "hue2": parsed = parseHueSaturation(data)
        case "expA":
            if let e = bef32(data, 2), let o = bef32(data, 6), let g = bef32(data, 10) {
                parsed = .exposure(Adjustment.Exposure(exposure: e, offset: o, gamma: g))
            } else {
                parsed = nil
            }
        case "levl":
            if let m = levelsRec(data, 2), let r = levelsRec(data, 12), let g = levelsRec(data, 22), let b = levelsRec(data, 32) {
                parsed = .levels(Adjustment.Levels(master: m, perChannel: [r, g, b], space: .rgb, black: levelsRec(data, 42) ?? LevelsChannel()))
            } else {
                parsed = nil
            }
        case "curv": parsed = parseCurves(data)
        case "selc": parsed = parseSelective(data)
        case "clrL": parsed = parseLookup(data)
        case "grdm": parsed = parseGradientMap(data)
        case "vibA": parsed = parseVibrance(data)
        case "blnc": parsed = parseColorBalance(data)
        case "blwh": parsed = parseBlackWhite(data)
        case "phfl": parsed = parsePhotoFilter(data)
        case "mixr": parsed = parseChannelMixer(data)
        default: parsed = nil
        }
        return parsed ?? unsupported(key, data)
    }

    private static func parseHueSaturation(_ data: [UInt8]) -> Adjustment? {
        guard let c = byte(data, 2) else { return nil }
        let colorize = c != 0
        let base = colorize ? 4 : 10
        // Six ranges from byte 16: four range values (degrees) then hue, saturation, lightness.
        var ranges = HueRange.defaults
        for i in 0 ..< 6 {
            let at = 16 + i * 14
            let v = (0 ..< 7).compactMap { k in bei16(data, at + 2 * k).map { Float($0) } }
            if v.count == 7 {
                ranges[i] = HueRange(hue: v[4], saturation: v[5], lightness: v[6], bounds: HueRange.canonicalBounds(SIMD4(v[0], v[1], v[2], v[3])))
            }
        }
        guard let h = bei16(data, base), let s = bei16(data, base + 2), let l = bei16(data, base + 4) else { return nil }
        return .hueSaturation(Adjustment.HueSaturation(hue: Float(h), saturation: Float(s), lightness: Float(l), colorize: colorize, ranges: ranges))
    }

    /// `grdm` (Adobe spec, "Gradient settings"): version (1, or 3 with an interpolation method key),
    /// reverse, dither, [method], name, colour stops (location /4096, midpoint %, colour space + four
    /// u16 components, 2 bytes), transparency stops, then smoothness (/4096) among noise-gradient
    /// fields. Smoothness, midpoints and the method are baked into dense stops like gradient fills.
    /// Stops may be in any plain colour space Photoshop writes (RGB, HSB, CMYK, Lab, Grayscale: a
    /// CMYK or Lab document stores them in its own space); they are converted to RGB through the
    /// colour-managed conversions (the installed CMYK converter). Noise gradients (no colour stops)
    /// and stops in other spaces (book colours) stay unsupported.
    private static func parseGradientMap(_ d: [UInt8]) -> Adjustment? {
        guard let version = be16(d, 0), let rev = byte(d, 2) else { return nil }
        let reverse = rev != 0
        let dither = (byte(d, 3) ?? 0) != 0
        var method: String?
        var at: Int
        switch version {
        case 1: at = 4
        case 3:
            guard d.count >= 8 else { return nil }
            method = String(decoding: d[4 ..< 8], as: UTF8.self)
            at = 8
        default: return nil
        }
        guard let nameLen = be32(d, at) else { return nil }
        at += 4 + Int(nameLen) * 2
        guard let n = be16(d, at) else { return nil }
        at += 2
        var stops: [ColorStop] = []
        var mids: [Float] = []
        stops.reserveCapacity(Int(n))
        for _ in 0 ..< Int(n) {
            guard let l = be32(d, at), let m = be32(d, at + 4), let space = be16(d, at + 8) else { return nil }
            guard let c0 = be16(d, at + 10), let c1 = be16(d, at + 12), let c2 = be16(d, at + 14), let c3 = be16(d, at + 16) else { return nil }
            guard let color = decodeKnownColor(space, [c0, c1, c2, c3]) else { return nil }
            stops.append(ColorStop(clampf(Float(l) / 4096, 0, 1), color))
            mids.append(Float(m) / 100)
            at += 20
        }
        if stops.count < 2 { return nil }
        guard let nt = be16(d, at) else { return nil }
        at += 2 + Int(nt) * 10 + 2 // transparency stops, expansion count
        guard let sm = be16(d, at) else { return nil }
        let smooth = Float(sm) / 4096
        // Midpoint k applies to the segment after stop k (in location order).
        let order = Blocks.totalOrderIndices(stops.map(\.location))
        let sortedMids = order.dropFirst().map { mids[$0] }
        let baked = GradientBake.bake(stops, Array(sortedMids), smooth, GradientBake.Method(code: method))
        let out = baked.map { GradientMapStop($0.location, $0.color.rgb) }
        let sorted = Blocks.totalOrderIndices(out.map(\.location)).map { out[$0] }
        return .gradientMap(Adjustment.GradientMap(stops: sorted, reverse: reverse, dither: dither))
    }

    /// `grdm` version 1 for `Adjustment.gradientMap` (Classic interpolation, Smoothness 0, so the
    /// stops are reproduced exactly).
    static func writeGradientMap(_ stops: [GradientMapStop], _ reverse: Bool, _ dither: Bool) -> [UInt8] {
        var v = BEWriter()
        v.u16(1)
        v.u8(reverse ? 1 : 0)
        v.u8(dither ? 1 : 0)
        v.unicodeUnits(Array("Custom".utf16) + [0])
        let n = min(stops.count, Int(UInt16.max))
        v.u16(UInt16(n))
        for s in stops.prefix(n) {
            v.u32(roundCast(clampf(s.location, 0, 1) * 4096))
            v.u32(50)
            v.u16(0)
            for k in 0 ..< 3 { v.u16(roundCast(clampf(s.rgb[k], 0, 1) * 65535)) }
            v.u16(0) // fourth component
            v.u16(0)
        }
        v.u16(2)
        for t: UInt32 in [0, 4096] {
            v.u32(t)
            v.u32(50)
            v.u16(255)
        }
        v.u16(2) // expansion count
        v.u16(0) // smoothness
        v.u16(32) // length
        v.u16(0) // mode
        v.u32(0) // random seed
        v.u16(0) // showing transparency
        v.u16(0) // using vector colour
        v.u32(2048) // roughness
        v.u16(3) // colour model
        for x: UInt16 in [0, 0, 0, 0, 0x8000, 0x8000, 0x8000, 0x8000] { v.u16(x) }
        v.u16(0)
        return v.bytes
    }

    /// `selc`: version, method (0 relative / 1 absolute), then 10 CMYK records of i16 percentages;
    /// record 0 is reserved, records 1...9 are reds … blacks.
    private static func parseSelective(_ d: [UInt8]) -> Adjustment? {
        guard be16(d, 0) == 1, d.count >= 84, let method = be16(d, 2) else { return nil }
        var adjustments = [SIMD4<Float>](repeating: .zero, count: 9)
        for r in 0 ..< 9 {
            for k in 0 ..< 4 {
                guard let x = bei16(d, 4 + (r + 1) * 8 + k * 2) else { return nil }
                adjustments[r][k] = Float(x)
            }
        }
        return .selectiveColor(Adjustment.SelectiveColor(relative: method == 0, adjustments: adjustments))
    }

    private static func parseLookup(_ d: [UInt8]) -> Adjustment? {
        if case let .success(a) = readLookup(d) { return a }
        return nil
    }

    /// `clrL`: version 1 + a versioned descriptor carrying the LUT file itself (`LUT3DFileData`, in
    /// the format named by `LUTFormat`). Profile-based lookups (abstract / device link) have no
    /// table and stay `Adjustment.unsupported`. Fails with the reason a block can't be read.
    private static func readLookup(_ d: [UInt8]) -> Result<Adjustment, LutError> {
        switch be16(d, 0) {
        case 1?: break
        case let v?: return .failure(LutError("unknown version \(v)"))
        case nil: return .failure(LutError("the block is truncated"))
        }
        let desc: PSDDescriptor
        do {
            desc = try PSDVersionedDescriptor.parsePrefix(Data(d[2...])).0.descriptor
        } catch {
            return .failure(LutError("unreadable settings (\(error))"))
        }
        // Photoshop's Color Lookup with no table chosen: an empty descriptor (the identity).
        if desc.items.isEmpty { return .success(.colorLookup(Adjustment.ColorLookup(name: "", lut: nil, size: 0, tetrahedral: false, dither: false))) }
        let bytes: [UInt8]
        switch desc["LUT3DFileData"] {
        case let .rawData(b)? where !b.isEmpty: bytes = [UInt8](b)
        case .some: return .failure(LutError("its LUT data is empty"))
        case nil: return .failure(LutError("it uses a colour profile (abstract or device link), not a LUT file, which isn't supported yet"))
        }
        let (ext, format): (String, String)
        switch Blocks.enumOf(desc, "LUTFormat") {
        case "LUTFormat3DL": (ext, format) = ("x.3dl", "3DL")
        case "LUTFormatLOOK": (ext, format) = ("x.look", "LOOK")
        default: (ext, format) = ("x.cube", "CUBE")
        }
        let lut: LutFile
        switch LutFile.parse(ext, bytes) {
        case let .success(l): lut = l
        case let .failure(e): return .failure(LutError("its \(format) LUT can't be read (\(e.message))"))
        }
        let name = Blocks.textOf(desc, "LUT3DFileName") ?? Blocks.textOf(desc, "NM  ") ?? ""
        return .success(.colorLookup(Adjustment.ColorLookup(name: name, lut: lut.data, size: UInt32(clamping: lut.size), tetrahedral: false,
                                                            dither: descBool(desc, "Dthr") ?? false)))
    }

    /// `vibA` (Adobe spec, "Vibrance"): a versioned descriptor with `vibrance` and `Strt`
    /// (saturation), both integers in -100...100. Photoshop omits a key whose value is 0.
    private static func parseVibrance(_ d: [UInt8]) -> Adjustment? {
        guard let desc = Blocks.parsePrefixVersioned(d) else { return nil }
        func get(_ k: String) -> Float { clampf(descNum(desc, k) ?? 0, -100, 100) }
        return .vibrance(Adjustment.Vibrance(vibrance: get("vibrance"), saturation: get("Strt")))
    }

    /// `blnc` (Adobe spec, "Color Balance"): shadows, midtones and highlights as three i16 each
    /// (cyan-red, magenta-green, yellow-blue, -100...100), then preserve luminosity (1 byte).
    private static func parseColorBalance(_ d: [UInt8]) -> Adjustment? {
        func tone(_ k: Int) -> SIMD3<Float>? {
            var out = SIMD3<Float>()
            for i in 0 ..< 3 {
                guard let x = bei16(d, (k * 3 + i) * 2) else { return nil }
                out[i] = clampf(Float(x), -100, 100)
            }
            return out
        }
        guard let s = tone(0), let m = tone(1), let h = tone(2), let p = byte(d, 18) else { return nil }
        return .colorBalance(Adjustment.ColorBalance(shadows: s, midtones: m, highlights: h, preserveLuminosity: p != 0))
    }

    /// Photoshop's default Black & White mix (reds, yellows, greens, cyans, blues, magentas) and tint.
    static let bwDefault: [Float] = [40, 60, 40, 60, 20, 80]
    static let bwKeys = ["Rd  ", "Yllw", "Grn ", "Cyn ", "Bl  ", "Mgnt"]
    static let bwTint = SIMD3<Float>(225.0 / 255.0, 211.0 / 255.0, 179.0 / 255.0)

    /// An `RGBC` colour (0...255 doubles) read in f64 so `write`'s encoding comes back bit-exact;
    /// other colour classes go through `Blocks.colorFromDesc`.
    private static func descRGB(_ d: PSDDescriptor) -> SIMD3<Float>? {
        func g(_ k: String) -> Double? {
            switch d[k] {
            case let .double(v)?: v
            case let .integer(v)?: Double(v)
            case let .unitFloat(_, v)?: v
            default: nil
            }
        }
        if d.classID.is("RGBC"), d["redFloat"] == nil {
            guard let r = g("Rd  "), let gg = g("Grn "), let b = g("Bl  ") else { return nil }
            func f(_ x: Double) -> Float { Float(clampd(x / 255, 0, 1)) }
            return SIMD3(f(r), f(gg), f(b))
        }
        return Blocks.colorFromDesc(d).map { c in
            let rgb = c.rgb
            return SIMD3(clampf(rgb.x, 0, 1), clampf(rgb.y, 0, 1), clampf(rgb.z, 0, 1))
        }
    }

    private static func rgbDesc(_ c: SIMD3<Float>) -> PSDDescriptor {
        func d(_ v: Float) -> DValue { .double(Double(clampf(v, 0, 1)) * 255) }
        return PSDDescriptor(classID: "RGBC").with("Rd  ", d(c.x)).with("Grn ", d(c.y)).with("Bl  ", d(c.z))
    }

    /// `blwh` (Adobe spec, "Black and White"): a versioned descriptor with the six colour weights
    /// (`Rd  `, `Yllw`, `Grn `, `Cyn `, `Bl  `, `Mgnt`, percent), `useTint` and `tintColor`.
    private static func parseBlackWhite(_ d: [UInt8]) -> Adjustment? {
        guard let desc = Blocks.parsePrefixVersioned(d) else { return nil }
        var weights = bwDefault
        for (i, k) in bwKeys.enumerated() {
            if let v = descNum(desc, k) { weights[i] = clampf(v, -200, 300) }
        }
        let tint: SIMD3<Float>? = (descBool(desc, "useTint") ?? false) ? (Blocks.getDesc(desc, "tintColor").flatMap(descRGB) ?? bwTint) : nil
        return .blackWhite(Adjustment.BlackWhite(weights: weights, tint: tint))
    }

    /// `phfl` (Adobe spec, "Photo Filter"): version (2 or 3); version 2 has a colour structure
    /// (colour space + four u16), version 3 "4 bytes each for XYZ color"; then density (u32
    /// percent) and preserve luminosity (1 byte).
    ///
    /// The spec gives no scale for the XYZ values. They are read as D50 XYZ (the ICC PCS) with 1.0 =
    /// 32768, the ICC 16-bit PCSXYZ encoding. That is inferred, not documented: the Photoshop CS2
    /// file in #3777 holds (24191, 25002, 3827), a bright warm yellow at this scale, and rendering it
    /// against Photoshop's export fit best between 30000 and 32768 (1.0 = 65536, a dull olive, was
    /// clearly worse).
    static let phflXYZOne: Float = 32768

    private static func parsePhotoFilter(_ d: [UInt8]) -> Adjustment? {
        guard let version = be16(d, 0) else { return nil }
        var color: SIMD3<Float>
        let at: Int
        switch version {
        case 2:
            guard let space = be16(d, 2), [0, 2, 7, 8].contains(space) else { return nil }
            guard let c0 = be16(d, 4), let c1 = be16(d, 6), let c2 = be16(d, 8), let c3 = be16(d, 10) else { return nil }
            color = decodeColor(space, [c0, c1, c2, c3]).rgb
            at = 12
        case 3:
            guard let x = be32(d, 2), let y = be32(d, 6), let z = be32(d, 10) else { return nil }
            let xyz = SIMD3(Float(x) / phflXYZOne, Float(y) / phflXYZOne, Float(z) / phflXYZOne)
            // Real colours stay below about 1.0; anything past 2.0 is not an XYZ colour.
            if xyz.x > 2 || xyz.y > 2 || xyz.z > 2 { return nil }
            let m = ColorConvert.xyzD50ToSRGB
            func row(_ r: SIMD3<Float>) -> Float { r.x * xyz.x + r.y * xyz.y + r.z * xyz.z }
            let lin = SIMD3(row(m[0]), row(m[1]), row(m[2]))
            color = SIMD3(ColorConvert.linearToSRGB(clampf(lin.x, 0, 1)), ColorConvert.linearToSRGB(clampf(lin.y, 0, 1)),
                          ColorConvert.linearToSRGB(clampf(lin.z, 0, 1)))
            at = 14
        default:
            return nil
        }
        guard let dens = be32(d, at), let p = byte(d, at + 4) else { return nil }
        let density = clampf(Float(dens) / 100, 0, 1)
        color = SIMD3(clampf(color.x, 0, 1), clampf(color.y, 0, 1), clampf(color.z, 0, 1))
        return .photoFilter(Adjustment.PhotoFilter(color: color, density: density, preserveLuminosity: p != 0))
    }

    /// `mixr` (Adobe spec, "Channel Mixer"): version (1), monochrome (u16), then one 10-byte record
    /// per output channel: four i16 source percentages (red, green, blue, and a fourth used only by
    /// CMYK documents) and an i16 constant (percent). With monochrome on, the first record is the
    /// gray mix (as ag-psd, MIT, documents).
    private static func parseChannelMixer(_ d: [UInt8]) -> Adjustment? {
        guard be16(d, 0) == 1, let mono = be16(d, 2) else { return nil }
        let monochrome = mono != 0
        func rec(_ r: Int) -> SIMD4<Float>? {
            let at = 4 + r * 10
            func v(_ k: Int) -> Float? { bei16(d, at + k * 2).map { clampf(Float($0), -200, 200) / 100 } }
            guard let a = v(0), let b = v(1), let c = v(2), let e = v(4) else { return nil }
            return SIMD4(a, b, c, e)
        }
        guard let first = rec(0) else { return nil }
        // A monochrome block may carry only the gray record.
        let g: SIMD4<Float>, b: SIMD4<Float>
        if monochrome {
            g = rec(1) ?? .zero
            b = rec(2) ?? .zero
        } else {
            guard let x = rec(1), let y = rec(2) else { return nil }
            (g, b) = (x, y)
        }
        return .channelMixer(Adjustment.ChannelMixer(matrix: [first, g, b], monochrome: monochrome))
    }
}

// MARK: - Colour structures (channel_map.rs)

extension AdjustMap {
    private static let spaceRGB: UInt16 = 0
    private static let spaceHSB: UInt16 = 1
    private static let spaceCMYK: UInt16 = 2
    private static let spaceLab: UInt16 = 7
    private static let spaceGray: UInt16 = 8

    /// A PSD colour structure as a colour; unknown spaces read the first three components as RGB.
    private static func decodeColor(_ space: UInt16, _ c: [UInt16]) -> PCColor {
        func n(_ v: UInt16) -> Float { Float(v) / 65535 }
        return decodeKnownColor(space, c) ?? .rgb(n(c[0]), n(c[1]), n(c[2]))
    }

    /// A PSD colour structure in one of the spaces Photoshop writes for plain colours (0 RGB, 1 HSB,
    /// 2 CMYK, 7 Lab, 8 Grayscale) as an RGB colour, or nil for any other space id. CMYK goes
    /// through the colour-managed conversion (`ColorConvert.cmyk`), Lab through the D50 Lab → sRGB
    /// conversion. `c` has four components.
    private static func decodeKnownColor(_ space: UInt16, _ c: [UInt16]) -> PCColor? {
        func n(_ v: UInt16) -> Float { Float(v) / 65535 }
        switch space {
        case spaceRGB:
            return .rgb(n(c[0]), n(c[1]), n(c[2]))
        case spaceHSB:
            let rgb = hsbToRGB(n(c[0]) * 360, n(c[1]), n(c[2]))
            return .rgb(rgb.x, rgb.y, rgb.z)
        case spaceCMYK:
            // Photoshop colour structures store CMYK inverted (65535 = no ink).
            let cmyk = PCColor(mode: .cmyk, c: SIMD4(1 - n(c[0]), 1 - n(c[1]), 1 - n(c[2]), 1 - n(c[3])), alpha: 1)
            let rgb = cmyk.rgb
            return .rgb(rgb.x, rgb.y, rgb.z)
        case spaceLab:
            let l = Float(min(c[0], 10000)) / 10000
            let a = Float(Int16(bitPattern: c[1])) / 100
            let b = Float(Int16(bitPattern: c[2])) / 100
            let rgb = PCColor(mode: .lab, c: SIMD4(l, (a + 128) / 255, (b + 128) / 255, 0), alpha: 1).rgb
            return .rgb(rgb.x, rgb.y, rgb.z)
        case spaceGray:
            let v = 1 - Float(min(c[0], 10000)) / 10000
            return .rgb(v, v, v)
        default:
            return nil
        }
    }

    /// HSB (hue in degrees, saturation and brightness 0...1) → RGB.
    private static func hsbToRGB(_ hIn: Float, _ sIn: Float, _ vIn: Float) -> SIMD3<Float> {
        let h = hIn.isFinite ? remEuclid(hIn, 360) / 60 : 0
        let (s, v) = (clampf(sIn, 0, 1), clampf(vIn, 0, 1))
        let f = h - h.rounded(.down)
        let (p, q, t) = (v * (1 - s), v * (1 - s * f), v * (1 - s * (1 - f)))
        let sector: UInt8 = satCast(h.rounded(.down))
        switch sector {
        case 0: return SIMD3(v, t, p)
        case 1: return SIMD3(q, v, p)
        case 2: return SIMD3(p, v, t)
        case 3: return SIMD3(p, q, v)
        case 4: return SIMD3(t, p, v)
        default: return SIMD3(v, p, q)
        }
    }
}

// MARK: - Writing helpers

extension AdjustMap {
    /// Rust `f32::clamp` (NaN stays NaN).
    static func clampf(_ v: Float, _ lo: Float, _ hi: Float) -> Float {
        var x = v
        if x < lo { x = lo }
        if x > hi { x = hi }
        return x
    }

    private static func clampd(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
        var x = v
        if x < lo { x = lo }
        if x > hi { x = hi }
        return x
    }

    /// Rust `f32::rem_euclid`.
    static func remEuclid(_ x: Float, _ m: Float) -> Float {
        let r = x.truncatingRemainder(dividingBy: m)
        return r < 0 ? r + abs(m) : r
    }

    private static func q255(_ v: Float) -> UInt16 { roundCast(clampf(v, 0, 1) * 255) }

    /// `v.round().clamp(-32768, 32767) as i16`.
    private static func clampI16(_ v: Float) -> Int16 { roundCast(v) }

    private static func levelsWrite(_ v: inout BEWriter, _ c: LevelsChannel) {
        v.u16(q255(c.inBlack))
        v.u16(q255(c.inWhite))
        v.u16(q255(c.outBlack))
        v.u16(q255(c.outWhite))
        v.u16(satCast(clampf((c.gamma * 100).rounded(.toNearestOrAwayFromZero), 1, 999)))
    }
}
