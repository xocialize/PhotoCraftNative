// Tagged-block helpers: descriptor access, colours, gradients, fills, patterns, placed-layer
// geometry, locks and labels, Advanced Blending and Blend If.
// Port of photocraft-io (crates/io/src/blocks.rs, and the blend-mode ID tables of
// effects_map.rs: BLEND_NAMES, BLEND_LONG_NAMES, blend_from_id, blend_long_value, blend_value),
// MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import PCDocument
import PCFoundation
import PCPSD

public typealias DValue = PSDDescriptor.Value
public typealias DID = PSDDescriptor.ID

public enum Blocks {
    // MARK: Advanced Blending, brst

    /// `brst` (channel blending restrictions): a list of big-endian u32 channel indices left out of
    /// blending → a bit mask (bit `i` = channel `i`; indices above 31 are ignored).
    public static func parseBrst(_ data: [UInt8]) -> UInt32 {
        var m: UInt32 = 0
        var i = 0
        while i + 4 <= data.count {
            let v = UInt32(data[i]) << 24 | UInt32(data[i + 1]) << 16 | UInt32(data[i + 2]) << 8 | UInt32(data[i + 3])
            if v < 32 { m |= 1 << v }
            i += 4
        }
        return m
    }

    /// Inverse of `parseBrst`; nil when every channel blends (no block).
    public static func brstData(_ mask: UInt32) -> [UInt8]? {
        guard mask != 0 else { return nil }
        var w = BEWriter()
        for i in 0 ..< 32 where mask & (1 << UInt32(i)) != 0 { w.u32(UInt32(i)) }
        return w.bytes
    }

    /// The Advanced Blending blocks, as (key, value for `a`, Photoshop's default value): `knko`
    /// (0 none, 1 shallow, 2 deep), `infx`, `clbl`, `tsly`, `lmgm`, `vmgm`. Each is one byte
    /// followed by three bytes of padding (Adobe PSD spec, "Additional Layer Information").
    public static func advancedFlags(_ a: AdvancedBlending) -> [(key: FourCC, value: UInt8, defaultValue: UInt8)] {
        [
            ("knko", a.knockout.psdValue, 0),
            ("infx", a.blendInterior ? 1 : 0, 0),
            ("clbl", a.blendClipped ? 1 : 0, 1),
            ("tsly", a.transparencyShapes ? 1 : 0, 1),
            ("lmgm", a.layerMaskHidesEffects ? 1 : 0, 0),
            ("vmgm", a.vectorMaskHidesEffects ? 1 : 0, 0),
        ]
    }

    /// Advanced Blending from a layer record's blocks (`block(key)` gives a block's data). A
    /// missing or empty block keeps Photoshop's default.
    public static func advancedFromBlocks(_ block: (FourCC) -> [UInt8]?) -> AdvancedBlending {
        var a = AdvancedBlending()
        func flag(_ k: FourCC) -> UInt8? { block(k)?.first }
        if let v = flag("knko") { a.knockout = Knockout(psdValue: v) }
        if let v = flag("infx") { a.blendInterior = v != 0 }
        if let v = flag("clbl") { a.blendClipped = v != 0 }
        if let v = flag("tsly") { a.transparencyShapes = v != 0 }
        if let v = flag("lmgm") { a.layerMaskHidesEffects = v != 0 }
        if let v = flag("vmgm") { a.vectorMaskHidesEffects = v != 0 }
        return a
    }

    /// Writes the Advanced Blending blocks into an exported layer's preserved block list: a block
    /// already there is rewritten in place (keeping Photoshop's block order); a missing one is
    /// added only when its value differs from the default, so plain layers gain no blocks.
    public static func putAdvanced(_ a: AdvancedBlending, _ raw: inout [(key: FourCC, data: [UInt8])]) {
        for (key, v, def) in advancedFlags(a) {
            if let i = raw.firstIndex(where: { $0.key == key }) {
                // Keep any extra bytes a reader wrote; the flag is the first byte.
                if raw[i].data.count < 4 { raw[i].data += [UInt8](repeating: 0, count: 4 - raw[i].data.count) }
                raw[i].data[0] = v
            } else if v != def {
                raw.append((key, [v, 0, 0, 0]))
            }
        }
    }

    // MARK: Blend If

    /// Layer-record blending ranges (composite gray source and destination ranges, then a source
    /// and destination range per channel) → Blend If. Full ranges map to the default.
    public static func blendIfFromRanges(_ r: PSDBlendingRanges) -> BlendIf {
        var ranges = r.ranges.map { BlendRangePair(BlendRange(bytes: $0.source), BlendRange(bytes: $0.destination)) }
        // Trailing full entries carry nothing (export pads them back): drop them, as `BlendIf.set` does.
        let keep = (ranges.lastIndex { !$0.isFull }).map { $0 + 1 } ?? 0
        ranges.removeSubrange(keep...)
        return BlendIf(ranges: ranges)
    }

    /// Inverse of `blendIfFromRanges` for a document with `channels` colour channels: one entry for
    /// gray plus one per channel (more when the setting stores more), unset entries full.
    public static func rangesFromBlendIf(_ b: BlendIf, _ channels: Int) -> PSDBlendingRanges {
        if b.isDefault { return .full(channels: channels) }
        let n = max(b.ranges.count, channels + 1)
        var data: [UInt8] = []
        for i in 0 ..< n {
            let p = b.get(i)
            data += p.this.bytes + p.underlying.bytes
        }
        return PSDBlendingRanges(data: data)
    }

    // MARK: Locks and labels

    /// `lspf` bits (Adobe spec: bit 0 transparency, 1 composite, 2 position). Artboard (bit 3,
    /// 0x08, as reference files write it) and "all" (bit 31) are undocumented. Older PhotoCraft
    /// builds wrote the artboard lock at bit 4 (0x10); that value is still accepted.
    public static func locksFromLspf(_ v: UInt32) -> Locks {
        Locks(transparency: v & 1 != 0, pixels: v & 2 != 0, position: v & 4 != 0, artboard: v & 0x08 != 0 || v & 0x10 != 0,
              all: v & 0x8000_0000 != 0)
    }

    /// Inverse of `locksFromLspf`.
    public static func lspfFromLocks(_ l: Locks) -> UInt32 {
        (l.transparency ? 1 : 0) | (l.pixels ? 2 : 0) | (l.position ? 4 : 0) | (l.artboard ? 8 : 0) | (l.all ? 0x8000_0000 : 0)
    }

    /// `lclr` index → label.
    public static func labelFromIndex(_ v: UInt16) -> LabelColor {
        switch v {
        case 1: .red
        case 2: .orange
        case 3: .yellow
        case 4: .green
        case 5: .blue
        case 6: .violet
        case 7: .gray
        // Photoshop 2024 added these without renumbering the original labels.
        case 8: .seafoam
        case 9: .indigo
        case 10: .magenta
        case 11: .fuchsia
        default: .none
        }
    }

    /// Label → `lclr` index.
    public static func labelIndex(_ l: LabelColor) -> UInt16 {
        switch l {
        case .none: 0
        case .red: 1
        case .orange: 2
        case .yellow: 3
        case .green: 4
        case .blue: 5
        case .violet: 6
        case .gray: 7
        case .seafoam: 8
        case .indigo: 9
        case .magenta: 10
        case .fuchsia: 11
        }
    }

    // MARK: Descriptor access

    /// Numeric value of `doub`, `UntF` or `long` (photocraft `num`; `comp` is not a number there).
    public static func num(_ v: DValue?) -> Double? {
        switch v {
        case let .double(d)?: d
        case let .unitFloat(_, value)?: value
        case let .integer(i)?: Double(i)
        default: nil
        }
    }

    /// The descriptor (or global object) under `key`.
    public static func getDesc(_ d: PSDDescriptor, _ key: String) -> PSDDescriptor? {
        switch d[key] {
        case let .descriptor(x)?, let .globalObject(x)?: x
        default: nil
        }
    }

    /// The enumerated value's identifier under `key` (4-char or long id), if present.
    public static func enumOf(_ d: PSDDescriptor, _ key: String) -> String? {
        if case let .enumerated(_, value)? = d[key] { return value.name }
        return nil
    }

    /// The enumerated value's raw identifier bytes under `key`.
    public static func enumBytes(_ d: PSDDescriptor, _ key: String) -> [UInt8]? {
        if case let .enumerated(_, value)? = d[key] { return value.bytes }
        return nil
    }

    /// `true` only for an explicit `bool` true.
    public static func boolOf(_ d: PSDDescriptor, _ key: String) -> Bool {
        if case .boolean(true)? = d[key] { return true }
        return false
    }

    /// The text under `key` (trailing NULs dropped).
    public static func textOf(_ d: PSDDescriptor, _ key: String) -> String? {
        if case let .text(t)? = d[key] { return t.string }
        return nil
    }

    /// A `Value.enumerated` (photocraft `Value::Enumerated { type_id: Id::new(t), value: Id::new(v) }`).
    public static func enumValue(_ type: String, _ value: String) -> DValue { .enumerated(type: DID(type), value: DID(value)) }

    /// `UntF` with a unit code.
    public static func unit(_ unit: String, _ v: Double) -> DValue { .unitFloat(unit: FourCC(unit), value: v) }

    /// NUL-terminated text value (photocraft `UnicodeString::new_nul`).
    public static func text(_ s: String) -> DValue { .text(.nulTerminated(s)) }

    /// Parses a version-16 descriptor at the start of `data` (trailing bytes allowed).
    public static func parsePrefixVersioned(_ data: [UInt8]) -> PSDDescriptor? {
        try? PSDVersionedDescriptor.parsePrefix(Data(data)).0.descriptor
    }

    /// Parses a version-16 descriptor at `offset` of `data` (trailing bytes allowed).
    public static func parsePrefixVersioned(_ data: [UInt8], from offset: Int) -> PSDDescriptor? {
        guard offset >= 0, offset <= data.count else { return nil }
        return parsePrefixVersioned(Array(data[offset...]))
    }

    /// A versioned (16) descriptor's bytes.
    public static func versionedBytes(_ d: PSDDescriptor) -> [UInt8] { [UInt8](PSDVersionedDescriptor(d).serialized()) }

    // MARK: Colours

    /// Descriptor colour (`RGBC`, `CMYC`, `Grsc`, `LbCl`, float RGB) → `PCColor`.
    public static func colorFromDesc(_ d: PSDDescriptor) -> PCColor? {
        func g(_ k: String) -> Float? { num(d[k]).map { Float($0) } }
        let id = d.classID.name
        if id == "RGBC" {
            if d["redFloat"] != nil {
                guard let r = g("redFloat"), let gg = g("greenFloat"), let b = g("blueFloat") else { return nil }
                return .rgb(r, gg, b)
            }
            guard let r = g("Rd  "), let gg = g("Grn "), let b = g("Bl  ") else { return nil }
            return .rgb(r / 255, gg / 255, b / 255)
        }
        if id == "CMYC" {
            guard let c = g("Cyn "), let m = g("Mgnt"), let y = g("Ylw "), let k = g("Blck") else { return nil }
            return PCColor(mode: .cmyk, c: SIMD4(c / 100, m / 100, y / 100, k / 100), alpha: 1)
        }
        if id == "Grsc" {
            guard let v = g("Gry ") else { return nil }
            return .gray(1 - v / 100)
        }
        if id == "LbCl" {
            // CIE L*a*b*: L 0...100, a / b −128...127 (stored like Lab pixels: offset by 128).
            guard let l = g("Lmnc"), let a = g("A   "), let b = g("B   ") else { return nil }
            return PCColor(mode: .lab, c: SIMD4(l / 100, (a + 128) / 255, (b + 128) / 255, 0), alpha: 1)
        }
        if d["redFloat"] != nil {
            guard let r = g("redFloat"), let gg = g("greenFloat"), let b = g("blueFloat") else { return nil }
            return .rgb(r, gg, b)
        }
        // Fall back to any RGB-like triple.
        guard let r = g("Rd  "), let gg = g("Grn "), let b = g("Bl  ") else { return nil }
        return .rgb(r / 255, gg / 255, b / 255)
    }

    /// `PCColor` → descriptor in its own model.
    public static func colorToDesc(_ c: PCColor) -> PSDDescriptor {
        func d(_ v: Float) -> DValue { .double(Double(v)) }
        switch c.mode {
        case .cmyk:
            return PSDDescriptor(classID: "CMYC").with("Cyn ", d(c.c[0] * 100)).with("Mgnt", d(c.c[1] * 100)).with("Ylw ", d(c.c[2] * 100))
                .with("Blck", d(c.c[3] * 100))
        case .grayscale:
            return PSDDescriptor(classID: "Grsc").with("Gry ", d((1 - c.c[0]) * 100))
        case .lab:
            return PSDDescriptor(classID: "LbCl").with("Lmnc", d(c.c[0] * 100)).with("A   ", d(c.c[1] * 255 - 128)).with("B   ", d(c.c[2] * 255 - 128))
        default:
            let rgb = c.rgb
            return PSDDescriptor(classID: "RGBC").with("Rd  ", d(rgb.x * 255)).with("Grn ", d(rgb.y * 255)).with("Bl  ", d(rgb.z * 255))
        }
    }

    // MARK: Gradients

    /// A gradient's interpolation method code. Photoshop (27.11) stores it as the enum
    /// `gradientsInterpolationMethod` (`Perc`, `Lnr `, `Smoo`, `Gcls`); `gs99` is a fallback.
    public static func gradientMethod(_ d: PSDDescriptor) -> String? {
        enumOf(d, "gradientsInterpolationMethod") ?? enumOf(d, "gs99")
    }

    /// `GrdT` gradient type.
    public static func gradientStyle(_ d: PSDDescriptor) -> GradientStyle {
        switch enumOf(d, "Type") {
        case "Rdl ": .radial
        case "Angl": .angle
        case "Rflc": .reflected
        case "Dmnd": .diamond
        default: .linear
        }
    }

    public static func gradientStyleValue(_ s: GradientStyle) -> DValue {
        let v: String
        switch s {
        case .linear: v = "Lnr "
        case .radial: v = "Rdl "
        case .angle: v = "Angl"
        case .reflected: v = "Rflc"
        case .diamond: v = "Dmnd"
        }
        return enumValue("GrdT", v)
    }

    /// Stops of a `Grdn` descriptor, baked to Photoshop's interpolation (smoothness `Intr`, stop
    /// midpoints, and the parent's interpolation method when given, see `gradientMethod`).
    public static func gradientStopsWith(_ grad: PSDDescriptor, _ method: String?) -> (stops: [ColorStop], opacity: [OpacityStop]) {
        let raw = gradientStopsRaw(grad)
        let stops = raw.stops.count >= 2 ? GradientBake.bake(raw.stops, raw.mids, raw.smooth, GradientBake.Method(code: method)) : raw.stops
        return (stops, raw.opacity)
    }

    /// A `Grdn` descriptor's stops as stored: colour stops (sorted), the midpoint of each segment
    /// between them, opacity stops and the smoothness (`Intr`, 0...1).
    public struct RawStops: Sendable {
        public var stops: [ColorStop]
        public var mids: [Float]
        public var opacity: [OpacityStop]
        public var smooth: Float
    }

    /// Stops of a gradient fill layer, kept editable: when Photoshop's interpolation is plain (no
    /// smoothness, Classic method) the stops stay as they are with their midpoints, else they are
    /// baked like `gradientStopsWith` (midpoints folded in). All-100 % opacity stops come back empty.
    public static func gradientStopsEditable(_ grad: PSDDescriptor, _ method: String?) -> RawStops {
        var raw = gradientStopsRaw(grad)
        let m = GradientBake.Method(code: method)
        // Lab stops (Lab documents) interpolate in L*a*b*, which only baking reproduces.
        let lab = raw.stops.allSatisfy { $0.color.mode == .lab }
        if raw.stops.count >= 2, raw.smooth > 0 || m != .classic || lab {
            raw.stops = GradientBake.bake(raw.stops, raw.mids, raw.smooth, m)
            raw.mids = []
        }
        if raw.mids.allSatisfy({ abs($0 - 0.5) < 1e-3 }) { raw.mids = [] }
        if raw.opacity.allSatisfy({ abs($0.opacity - 1) < 1e-4 }) { raw.opacity = [] }
        return raw
    }

    static func gradientStopsRaw(_ grad: PSDDescriptor) -> RawStops {
        var stops: [ColorStop] = []
        var mids: [Float] = []
        var opacity: [OpacityStop] = []
        if case let .list(items)? = grad["Clrs"] {
            for it in items {
                guard case let .descriptor(s) = it else { continue }
                let loc = Float(num(s["Lctn"]) ?? 0) / 4096
                if let c = getDesc(s, "Clr ").flatMap(colorFromDesc) {
                    stops.append(ColorStop(loc, c))
                    mids.append(Float(num(s["Mdpn"]) ?? 50) / 100)
                }
            }
        }
        // Midpoint k applies to the segment after stop k (stable sort by location, NaN last like
        // Rust's `total_cmp`).
        let order = totalOrderIndices(stops.map(\.location))
        let sortedMids: [Float] = order.dropFirst().map { $0 < mids.count ? mids[$0] : 0.5 }
        var sorted = order.map { stops[$0] }
        if sorted.count != stops.count { sorted = stops }
        let smooth = num(grad["Intr"]).map { Float($0 / 4096) } ?? 0
        if case let .list(items)? = grad["Trns"] {
            for it in items {
                guard case let .descriptor(s) = it else { continue }
                let loc = Float(num(s["Lctn"]) ?? 0) / 4096
                opacity.append(OpacityStop(loc, Float(num(s["Opct"]) ?? 100) / 100))
            }
        }
        return RawStops(stops: sorted, mids: sortedMids, opacity: opacity, smooth: smooth)
    }

    /// Indices of `keys` in Rust's stable `sort_by(total_cmp)` order (IEEE totalOrder, ties kept
    /// in input order).
    public static func totalOrderIndices(_ keys: [Float]) -> [Int] {
        keys.indices.sorted { a, b in
            let (x, y) = (keys[a], keys[b])
            let le = x.isTotallyOrdered(belowOrEqualTo: y), ge = y.isTotallyOrdered(belowOrEqualTo: x)
            return le && ge ? a < b : le
        }
    }

    /// A `Grdn` descriptor for colour and opacity stops.
    public static func gradientDesc(_ stops: [ColorStop], _ opacity: [OpacityStop]) -> PSDDescriptor {
        gradientDescWith(stops, opacity, [])
    }

    /// `gradientDesc` with colour midpoints (one per segment between the sorted stops; each is
    /// stored on the stop that ends its segment, as `gradientStopsWith` reads it).
    public static func gradientDescWith(_ stopsIn: [ColorStop], _ opacity: [OpacityStop], _ mids: [Float]) -> PSDDescriptor {
        var stops = stopsIn
        if !mids.isEmpty {
            stops = totalOrderIndices(stops.map(\.location)).map { stops[$0] }
        }
        let clrs: [DValue] = stops.enumerated().map { i, s in
            let mid = i >= 1 && i - 1 < mids.count ? mids[i - 1] : 0.5
            return .descriptor(PSDDescriptor(classID: "Clrt")
                .with("Clr ", .descriptor(colorToDesc(s.color)))
                .with("Type", enumValue("Clry", "UsrS"))
                .with("Lctn", .integer(roundCast(s.location * 4096)))
                .with("Mdpn", .integer(roundCast(min(max(mid, 0.05), 0.95) * 100))))
        }
        let op: [OpacityStop] = opacity.isEmpty ? stops.map { OpacityStop($0.location, $0.color.alpha) } : opacity
        let trns: [DValue] = op.map { o in
            .descriptor(PSDDescriptor(classID: "TrnS")
                .with("Opct", unit("#Prc", Double(o.opacity * 100)))
                .with("Lctn", .integer(roundCast(o.location * 4096)))
                .with("Mdpn", .integer(50)))
        }
        return PSDDescriptor(classID: "Grdn")
            .with("Nm  ", text("Custom"))
            .with("GrdF", enumValue("GrdF", "CstS"))
            // Our stops interpolate linearly (Photoshop smoothness is baked into them on import).
            .with("Intr", .double(0))
            .with("Clrs", .list(clrs))
            .with("Trns", .list(trns))
    }

    /// Opacity stops of a `Grdn` descriptor with Photoshop's smoothness and midpoints applied (the
    /// same curve as the colour stops, Classic interpolation), densely sampled.
    static func smoothedOpacityStops(_ grad: PSDDescriptor) -> [OpacityStop] {
        var stops: [ColorStop] = []
        var mids: [Float] = []
        if case let .list(items)? = grad["Trns"] {
            for it in items {
                guard case let .descriptor(s) = it else { continue }
                let a = Float(num(s["Opct"]) ?? 100) / 100
                stops.append(ColorStop(Float(num(s["Lctn"]) ?? 0) / 4096, .rgb(a, a, a, 1)))
                mids.append(Float(num(s["Mdpn"]) ?? 50) / 100)
            }
        }
        let order = totalOrderIndices(stops.map(\.location))
        let m: [Float] = order.dropFirst().compactMap { $0 < mids.count ? mids[$0] : nil }
        let smooth = num(grad["Intr"]).map { Float($0 / 4096) } ?? 0
        let baked = stops.count >= 2 ? GradientBake.bake(stops, m, smooth, .classic) : stops
        return baked.map { OpacityStop($0.location, $0.color.rgb.x) }
    }

    // MARK: Fills

    /// Parses a fill block (`SoCo`, `GdFl`, `PtFl`); block data may carry trailing padding.
    public static func parseFill(_ key: FourCC, _ data: [UInt8]) -> Fill? {
        guard let d = parsePrefixVersioned(data) else { return nil }
        return fillFromDesc(key, d)
    }

    /// A fill from its descriptor (`SoCo`/`GdFl`/`PtFl` layout; also the `solidColorLayer`,
    /// `gradientLayer` and `patternLayer` contents of shape strokes).
    public static func fillFromDesc(_ key: FourCC, _ d: PSDDescriptor) -> Fill? {
        switch key {
        case "SoCo":
            guard let c = getDesc(d, "Clr ").flatMap(colorFromDesc) else { return nil }
            return .solid(c)
        case "GdFl":
            let angle = Float(num(d["Angl"]) ?? 90)
            let scale = num(d["Scl "]).map { Float($0) / 100 } ?? 1
            let raw = getDesc(d, "Grad").map { gradientStopsEditable($0, gradientMethod(d)) }
            var stops = raw?.stops ?? []
            let midpoints = raw?.mids ?? []
            // Opacity stops with Photoshop's smoothness and opacity midpoints applied; none when opaque.
            var opacityStops = getDesc(d, "Grad").map(smoothedOpacityStops) ?? []
            if opacityStops.allSatisfy({ $0.opacity >= 1 - 1e-4 }) { opacityStops = [] }
            if stops.isEmpty { stops = [ColorStop(0, .black), ColorStop(1, .white)] }
            func pct(_ o: PSDDescriptor, _ k: String) -> Float { num(o[k]).map { Float($0) / 100 } ?? 0 }
            let offset = getDesc(d, "Ofst").map { SIMD2(pct($0, "Hrzn"), pct($0, "Vrtc")) } ?? .zero
            var align = true
            if case .boolean(false)? = d["Algn"] { align = false }
            return .gradient(GradientFill(stops: stops, angle: angle, scale: scale, style: gradientStyle(d), reverse: boolOf(d, "Rvrs"),
                                          opacityStops: opacityStops, midpoints: midpoints, offset: offset, dither: boolOf(d, "Dthr"), align: align))
        case "PtFl":
            let (name, id) = patternRef(d)
            let scale = num(d["Scl "]).map { Float($0) / 100 } ?? 1
            let (angle, link, phase) = patternPlacement(d)
            return .pattern(PatternFill(name: name, scale: scale, id: id, angle: angle, link: link, phase: phase))
        default:
            return nil
        }
    }

    /// Serialises a fill to its block (key, versioned descriptor bytes).
    public static func writeFill(_ f: Fill) -> (key: FourCC, data: [UInt8]) {
        let (k, d) = fillToDesc(f)
        return (k, versionedBytes(d))
    }

    /// A fill as (block key, descriptor with class `null`).
    public static func fillToDesc(_ f: Fill) -> (key: FourCC, descriptor: PSDDescriptor) {
        switch f {
        case let .solid(c):
            return ("SoCo", PSDDescriptor(classID: "null").with("Clr ", .descriptor(colorToDesc(c))))
        case let .gradient(g):
            func prc(_ v: Float) -> DValue { unit("#Prc", Double(v * 100)) }
            var d = PSDDescriptor(classID: "null")
                .with("Angl", unit("#Ang", Double(g.angle)))
                .with("Type", gradientStyleValue(g.style))
                .with("Scl ", prc(g.scale))
                .with("Grad", .descriptor(gradientDescWith(g.stops, g.opacityStops, g.midpoints)))
            if g.reverse { d = d.with("Rvrs", .boolean(true)) }
            if g.dither { d = d.with("Dthr", .boolean(true)) }
            if !g.align { d = d.with("Algn", .boolean(false)) }
            if g.offset != .zero {
                d = d.with("Ofst", .descriptor(PSDDescriptor(classID: "Pnt ").with("Hrzn", prc(g.offset.x)).with("Vrtc", prc(g.offset.y))))
            }
            return ("GdFl", d)
        case let .pattern(p):
            let d = PSDDescriptor(classID: "null")
                .with("Scl ", unit("#Prc", Double(p.scale * 100)))
                .with("Ptrn", .descriptor(patternRefDesc(p.name, p.id)))
            return ("PtFl", withPatternPlacement(d, p.angle, p.link, p.phase))
        }
    }

    // MARK: Patterns

    /// Pattern name and id (`Ptrn` → `Nm  `, `Idnt`) of a pattern fill / overlay descriptor.
    public static func patternRef(_ d: PSDDescriptor) -> (name: String, id: String) {
        let p = getDesc(d, "Ptrn")
        return (p.flatMap { textOf($0, "Nm  ") } ?? "", p.flatMap { textOf($0, "Idnt") } ?? "")
    }

    /// The `Ptrn` reference descriptor (the id is omitted when unknown).
    public static func patternRefDesc(_ name: String, _ id: String) -> PSDDescriptor {
        let p = PSDDescriptor(classID: "Ptrn").with("Nm  ", text(name))
        return id.isEmpty ? p : p.with("Idnt", text(id))
    }

    /// Angle (`Angl`, degrees), link with layer (`Algn`, default on) and phase (`phase` point) of a
    /// pattern fill / overlay descriptor.
    public static func patternPlacement(_ d: PSDDescriptor) -> (angle: Float, link: Bool, phase: SIMD2<Float>) {
        let angle = Float(num(d["Angl"]) ?? 0)
        var link = true
        if case .boolean(false)? = d["Algn"] { link = false }
        let phase = getDesc(d, "phase").map { SIMD2(Float(num($0["Hrzn"]) ?? 0), Float(num($0["Vrtc"]) ?? 0)) } ?? .zero
        return (angle, link, phase)
    }

    /// Adds the keys read by `patternPlacement` (angle only when non-zero).
    public static func withPatternPlacement(_ d: PSDDescriptor, _ angle: Float, _ link: Bool, _ phase: SIMD2<Float>) -> PSDDescriptor {
        var d = d
        if angle != 0 { d = d.with("Angl", unit("#Ang", Double(angle))) }
        return d.with("Algn", .boolean(link)).with("phase", .descriptor(PSDDescriptor(classID: "Pnt ")
                .with("Hrzn", .double(Double(phase.x))).with("Vrtc", .double(Double(phase.y)))))
    }

    // MARK: Placed layers

    /// The warp of a placed layer (`SoLd`/`SoLE` `warp` descriptor): style, bend, distortions,
    /// axis, bounds and, for `warpCustom`, the 4 × 4 `customEnvelopeWarp` mesh. Read-only: the raw
    /// block is what gets written back. nil when absent or `warpNone` with no mesh.
    public static func parsePlacedWarp(_ key: FourCC, _ data: [UInt8]) -> Warp? {
        guard key == "SoLd" || key == "SoLE", let d = parsePrefixVersioned(data, from: 8), let w = getDesc(d, "warp") else { return nil }
        guard let styleName = enumOf(w, "warpStyle"), let style = WarpStyle.parse(styleName), let b = getDesc(w, "bounds") else { return nil }
        guard let left = num(b["Left"]), let top = num(b["Top "]), let right = num(b["Rght"]), let bottom = num(b["Btom"]) else { return nil }
        var warp = Warp.preset(style, bend: num(w["warpValue"]) ?? 0, bounds: SIMD4(left, top, right, bottom))
        warp.hDistort = num(w["warpPerspective"]) ?? 0
        warp.vDistort = num(w["warpPerspectiveOther"]) ?? 0
        warp.vertical = enumOf(w, "warpRotate") == "Vrtc"
        if style == .custom {
            guard let env = getDesc(w, "customEnvelopeWarp"), case let .objectArray(arr)? = env["meshPoints"] else { return nil }
            func vals(_ k: String) -> [Double]? {
                if case let .unitFloats(_, values)? = arr.body[k] { return values }
                return nil
            }
            guard let xs = vals("Hrzn"), let ys = vals("Vrtc"), xs.count == 16, ys.count == 16 else { return nil }
            let mesh = BezierMesh(us: [0, 1], vs: [0, 1], points: zip(xs, ys).map { SIMD2($0, $1) })
            warp.mesh = mesh.isValid ? mesh : nil
            if warp.mesh == nil { return nil }
        }
        return warp.isIdentity ? nil : warp
    }

    /// Text content and transform from a `TySh` block (best effort, when the typed parser fails).
    public static func parseTySh(_ data: [UInt8]) -> (text: String, transform: PCAffine)? {
        var r = BEReader(data, at: 2)
        var m: [Double] = []
        for _ in 0 ..< 6 { guard let v = try? r.f64() else { return nil }; m.append(v) }
        // Text version (2) at 50, descriptor version (4) at 52, descriptor at 56.
        guard data.count >= 52 else { return nil }
        let text = parsePrefixVersioned(data, from: 52).flatMap { textOf($0, "Txt ") }
        return (text ?? "", PCAffine(m: m))
    }

    /// The source-space box Photoshop maps onto a placed layer's `Trnf` quad: the bounding box of
    /// a single-patch custom warp's 16 control points (which may spill past the source), else the
    /// source rect `0..w × 0..h`. A degenerate or non-finite box falls back to the source rect.
    public static func placedFrame(_ warp: Warp?, _ w: Double, _ h: Double) -> SIMD4<Double> {
        let rect = SIMD4(0, 0, w, h)
        guard let wp = warp, wp.style == .custom, let m = wp.mesh, m.points.count == 16 else { return rect }
        var b = SIMD4(Double.infinity, .infinity, -.infinity, -.infinity)
        for p in m.points {
            b = SIMD4(Swift.min(b.x, p.x), Swift.min(b.y, p.y), Swift.max(b.z, p.x), Swift.max(b.w, p.y))
        }
        let ok = b.x.isFinite && b.y.isFinite && b.z.isFinite && b.w.isFinite && b.z - b.x > 1e-9 && b.w - b.y > 1e-9
        return ok ? b : rect
    }

    /// Smart object identifier and transform from `SoLd`/`SoLE` (best effort; `PlLd` gives none).
    public static func parseSmart(_ key: FourCC, _ data: [UInt8]) -> (id: String, transform: PCAffine) {
        // SoLd: 'soLD' + version(4) + versioned descriptor.
        guard key == "SoLd" || key == "SoLE", let d = parsePrefixVersioned(data, from: 8) else { return ("", .identity) }
        let id = textOf(d, "Idnt") ?? ""
        var affine = PCAffine.identity
        if case let .list(pts)? = d["Trnf"], let sz = getDesc(d, "Sz  ") {
            let p = pts.compactMap { num($0) }
            let (w, h) = (num(sz["Wdth"]) ?? 0, num(sz["Hght"]) ?? 0)
            if p.count == 8, w > 0, h > 0 {
                let f = placedFrame(parsePlacedWarp(key, data), w, h)
                let (bw, bh) = (f.z - f.x, f.w - f.y)
                let (a, b, c, dd) = ((p[2] - p[0]) / bw, (p[3] - p[1]) / bw, (p[6] - p[0]) / bh, (p[7] - p[1]) / bh)
                affine = PCAffine(a: a, b: b, c: c, d: dd, e: p[0] - a * f.x - c * f.y, f: p[1] - b * f.x - dd * f.y)
            }
        }
        return (id, affine)
    }

    /// The projective placement of a `SoLd` / `SoLE` block whose corners aren't a parallelogram
    /// (Distort, Perspective): source pixels → document pixels, row-major 3×3. Read from
    /// `nonAffineTransform` (the placed corners), else `Trnf`. nil for affine placements.
    public static func parseSmartPerspective(_ key: FourCC, _ data: [UInt8]) -> [Double]? {
        guard key == "SoLd" || key == "SoLE", let d = parsePrefixVersioned(data, from: 8), let sz = getDesc(d, "Sz  "),
              let w = num(sz["Wdth"]), let h = num(sz["Hght"]) else { return nil }
        func quad(_ k: String) -> [SIMD2<Double>]? {
            guard case let .list(pts)? = d[k] else { return nil }
            let p = pts.compactMap { num($0) }
            guard p.count == 8, p.allSatisfy(\.isFinite) else { return nil }
            return [SIMD2(p[0], p[1]), SIMD2(p[2], p[3]), SIMD2(p[4], p[5]), SIMD2(p[6], p[7])]
        }
        guard let q = quad("nonAffineTransform") ?? quad("Trnf") else { return nil }
        // A parallelogram (top-left + bottom-right = top-right + bottom-left) is affine.
        let mag = q.reduce(0.0) { Swift.max($0, Swift.max(abs($1.x), abs($1.y))) }
        let tol = 1e-6 * (1 + mag)
        let parallel = abs(q[0].x + q[2].x - q[1].x - q[3].x) <= tol && abs(q[0].y + q[2].y - q[1].y - q[3].y) <= tol
        if parallel || w <= 0 || h <= 0 { return nil }
        return Homography.rectToQuad(SIMD4(0, 0, w, h), q)?.m
    }

    /// `masterFXSwitch` from an `lfx2` block (defaults to true).
    public static func effectsEnabled(_ lfx2: [UInt8]) -> Bool {
        guard let d = parsePrefixVersioned(lfx2, from: 4), case let .boolean(b)? = d["masterFXSwitch"] else { return true }
        return b
    }

    // MARK: Blend-mode descriptor IDs (effects_map.rs)

    /// Blend modes by descriptor `BlnM` code.
    public static let blendNames: [(BlendMode, String)] = [
        (.normal, "Nrml"), (.dissolve, "Dslv"), (.darken, "Drkn"), (.multiply, "Mltp"), (.colorBurn, "CBrn"),
        (.linearBurn, "linearBurn"), (.darkerColor, "darkerColor"), (.lighten, "Lghn"), (.screen, "Scrn"), (.colorDodge, "CDdg"),
        (.linearDodge, "linearDodge"), (.lighterColor, "lighterColor"), (.overlay, "Ovrl"), (.softLight, "SftL"), (.hardLight, "HrdL"),
        (.vividLight, "vividLight"), (.linearLight, "linearLight"), (.pinLight, "pinLight"), (.hardMix, "hardMix"), (.difference, "Dfrn"),
        (.exclusion, "Xclu"), (.subtract, "blendSubtraction"), (.divide, "blendDivide"), (.hue, "H   "), (.saturation, "Strt"),
        (.color, "Clr "), (.luminosity, "Lmns"), (.passThrough, "passThrough"),
    ]

    /// Long (string-ID) names some writers use instead of the four-character codes, for the modes
    /// whose code is a short ID (`BlnM` `multiply` = `Mltp`).
    public static let blendLongNames: [(BlendMode, String)] = [
        (.normal, "normal"), (.dissolve, "dissolve"), (.darken, "darken"), (.multiply, "multiply"), (.colorBurn, "colorBurn"),
        (.lighten, "lighten"), (.screen, "screen"), (.colorDodge, "colorDodge"), (.overlay, "overlay"), (.softLight, "softLight"),
        (.hardLight, "hardLight"), (.difference, "difference"), (.exclusion, "exclusion"), (.hue, "hue"), (.saturation, "saturation"),
        (.color, "color"), (.luminosity, "luminosity"),
    ]

    /// A blend-mode enum from either its four-character code or its long string ID.
    public static func blendFromId(_ v: String) -> BlendMode? {
        (blendNames + blendLongNames).first { $0.1 == v }?.0
    }

    /// A `BlnM` enum with the long string ID where the mode has one (`multiply`, `overlay`), as
    /// Photoshop writes smart-filter blend options; the four-character code otherwise.
    public static func blendLongValue(_ m: BlendMode) -> DValue {
        let n = (blendLongNames + blendNames).first { $0.0 == m }?.1 ?? "normal"
        return enumValue("BlnM", n)
    }

    /// A `BlnM` enum with the four-character code (layer effects).
    public static func blendValue(_ m: BlendMode) -> DValue {
        enumValue("BlnM", blendNames.first { $0.0 == m }?.1 ?? "Nrml")
    }
}

/// A 3×3 projective matrix, row-major: `[x', y', w'] = H · [x, y, 1]`.
/// Port of photocraft-algo (crates/algo/src/transform.rs: `Homography`), MIT OR Apache-2.0,
/// © ArtCraft Team and the PhotoCraft contributors.
public struct Homography: Equatable, Sendable {
    public var m: [Double]

    public init(_ m: [Double]) { self.m = m }

    public static let identity = Homography([1, 0, 0, 0, 1, 0, 0, 0, 1])

    public func apply(_ x: Double, _ y: Double) -> SIMD2<Double> {
        let w = m[6] * x + m[7] * y + m[8]
        return SIMD2((m[0] * x + m[1] * y + m[2]) / w, (m[3] * x + m[4] * y + m[5]) / w)
    }

    public func mul(_ o: Homography) -> Homography {
        var r = [Double](repeating: 0, count: 9)
        for i in 0 ..< 3 { for j in 0 ..< 3 { r[i * 3 + j] = (0 ..< 3).reduce(0) { $0 + m[i * 3 + $1] * o.m[$1 * 3 + j] } } }
        return Homography(r)
    }

    public var inverse: Homography? {
        let c = [m[4] * m[8] - m[5] * m[7], m[2] * m[7] - m[1] * m[8], m[1] * m[5] - m[2] * m[4],
                 m[5] * m[6] - m[3] * m[8], m[0] * m[8] - m[2] * m[6], m[2] * m[3] - m[0] * m[5],
                 m[3] * m[7] - m[4] * m[6], m[1] * m[6] - m[0] * m[7], m[0] * m[4] - m[1] * m[3]]
        let det = m[0] * c[0] + m[1] * c[3] + m[2] * c[6]
        if abs(det) < 1e-12 { return nil }
        return Homography(c.map { $0 / det })
    }

    /// Unit square → quad (corners in order: (0,0), (1,0), (1,1), (0,1)).
    static func squareToQuad(_ q: [SIMD2<Double>]) -> Homography? {
        guard q.count == 4 else { return nil }
        let (x0, y0, x1, y1, x2, y2, x3, y3) = (q[0].x, q[0].y, q[1].x, q[1].y, q[2].x, q[2].y, q[3].x, q[3].y)
        let (sx, sy) = (x0 - x1 + x2 - x3, y0 - y1 + y2 - y3)
        if abs(sx) < 1e-12, abs(sy) < 1e-12 {
            return Homography([x1 - x0, x3 - x0, x0, y1 - y0, y3 - y0, y0, 0, 0, 1])
        }
        let (dx1, dx2, dy1, dy2) = (x1 - x2, x3 - x2, y1 - y2, y3 - y2)
        let den = dx1 * dy2 - dx2 * dy1
        if abs(den) < 1e-12 { return nil }
        let g = (sx * dy2 - dx2 * sy) / den
        let h = (dx1 * sy - sx * dy1) / den
        return Homography([x1 - x0 + g * x1, x3 - x0 + h * x3, x0, y1 - y0 + g * y1, y3 - y0 + h * y3, y0, g, h, 1])
    }

    /// The transform taking rectangle `r` (x0, y0, x1, y1) onto `quad` (corners clockwise from
    /// top-left). nil for degenerate quads.
    public static func rectToQuad(_ r: SIMD4<Double>, _ quad: [SIMD2<Double>]) -> Homography? {
        let (w, h) = (r.z - r.x, r.w - r.y)
        if w <= 0 || h <= 0 { return nil }
        let toUnit = Homography([1 / w, 0, -r.x / w, 0, 1 / h, -r.y / h, 0, 0, 1])
        return squareToQuad(quad)?.mul(toUnit)
    }
}
