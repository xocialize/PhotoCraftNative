// Port of photocraft-io (crates/io/src/displace_map.rs), MIT OR Apache-2.0, © ArtCraft Team and the
// PhotoCraft contributors.
//
// Displace smart filters (`Fltr` class `Dspl`) as observed in Photoshop-authored mockup PSDs.
//
// The filter descriptor holds the scales (`HrzS`, `VrtS`, percent), the fit (`DspM`: `StrF`
// stretch or `Tile`), the undefined areas (`UndA`: `RptE` repeat edge pixels or `WrpA` wrap),
// an alias to the map file on the author's disk (`DspF`, usually unavailable), `EmbF` (true) and
// the map itself, embedded as raw data (`DspD`, type `tdta`):
//
//     u32 LE height, u32 LE width, u16 LE mode (3 observed), then two 8-bit planes of
//     width * height bytes (horizontal map, vertical map), then padding
//
// The whole `filterFX` item (with the map) is kept verbatim in the params as a template
// (`templateKey`), so the filter re-renders, survives `.pcraft` and is written back to PSD with
// only the editable settings replaced. Anything else (another mode, a missing or truncated map,
// unknown enum values) stays an opaque `SmartMap.unsupportedFilter`.

import Foundation
import PCDocument
import PCFoundation
import PCIOCore
import PCPSD

public enum DisplaceMap {
    static let className = "Dspl"
    /// The PhotoCraft command of a Displace smart filter.
    public static let command = "filter.distort.displace"
    static let filterID: Int32 = SmartMap.code("Dspl")
    /// The params key holding the whole PSD item (hex).
    public static let templateKey = "__displacePsd"
    /// The embedded map (raw data).
    static let mapKey = "DspD"
    /// `tdta` header: height, width (u32 LE) and mode (u16 LE).
    static let header = 10
    /// The only map layout seen in Photoshop files: two 8-bit planes.
    static let modeTwoPlanes: UInt16 = 3
    /// 8K × 8K: far beyond the observed document-sized maps, and bounds the Float map we build.
    static let maxMapPixels = 1 << 26
    /// The template is the item plus the map; a little room for the rest of the descriptor.
    static let maxTemplateBytes = 2 * maxMapPixels + (1 << 20)

    static let fits: [(code: String, name: String)] = [("StrF", "stretch"), ("Tile", "tile")]
    static let undefined: [(code: String, name: String)] = [("RptE", "repeat"), ("WrpA", "wrap")]

    /// A parsed embedded map: size and the two 8-bit planes.
    struct EmbeddedMap: Equatable {
        var width: Int
        var height: Int
        var horizontal: ArraySlice<UInt8>
        var vertical: ArraySlice<UInt8>
    }

    /// Parses an embedded displacement map; nil for any other mode, a zero or oversized map, or a
    /// blob shorter than the header plus both planes.
    static func parseMap(_ data: [UInt8]) -> EmbeddedMap? {
        func u32At(_ i: Int) -> UInt32? {
            guard i + 4 <= data.count else { return nil }
            return (0 ..< 4).reduce(UInt32(0)) { $0 | UInt32(data[i + $1]) << (8 * UInt32($1)) }
        }
        guard let h32 = u32At(0), let w32 = u32At(4), data.count >= header else { return nil }
        let (height, width) = (Int(h32), Int(w32))
        let mode = UInt16(data[8]) | UInt16(data[9]) << 8
        let (n, o) = width.multipliedReportingOverflow(by: height)
        if o || mode != modeTwoPlanes || n == 0 || n > maxMapPixels { return nil }
        guard header + 2 * n <= data.count else { return nil }
        return EmbeddedMap(width: width, height: height, horizontal: data[header ..< header + n], vertical: data[header + n ..< header + 2 * n])
    }

    static func fltrMap(_ item: PSDDescriptor) -> EmbeddedMap? {
        guard case let .rawData(b)? = SmartMap.getDesc(item, "Fltr")?[mapKey] else { return nil }
        return parseMap([UInt8](b))
    }

    static func lookup(_ table: [(code: String, name: String)], _ v: [UInt8]) -> String? {
        table.first { Array($0.code.utf8) == v }?.name
    }

    /// Editable settings of a `Dspl` descriptor, nil when one is missing or unknown.
    static func settings(_ f: PSDDescriptor) -> [String: JSONValue]? {
        func scale(_ k: String) -> Double? {
            guard let v = Blocks.num(f[k]), v.isFinite, (-999.0 ... 999.0).contains(v) else { return nil }
            return v
        }
        guard let h = scale("HrzS"), let v = scale("VrtS"),
              let fitCode = Blocks.enumBytes(f, "DspM"), let fit = lookup(fits, fitCode),
              let undCode = Blocks.enumBytes(f, "UndA"), let und = lookup(undefined, undCode) else { return nil }
        return ["horizontal": .number(h), "vertical": .number(v), "fit": .string(fit), "undefinedAreas": .string(und)]
    }

    /// `filter.distort.displace` params for a Displace item with an embedded map.
    static func importParams(_ item: PSDDescriptor) -> JSONValue? {
        guard let f = SmartMap.getDesc(item, "Fltr"), f.classID.is(className), var params = settings(f), fltrMap(item) != nil else { return nil }
        // Neutral blending in the template: the model's own fields replace it on export.
        var template = item
        SmartMap.set(&template, "blendOptions", SmartMap.blendOptions(SmartMap.neutralFilter))
        SmartMap.set(&template, "enab", .boolean(true))
        params[templateKey] = .string(SmartMap.toHex(template.serializedBytes()))
        return .object(params)
    }

    /// The template item of `params`, checked to be a Displace filter with a readable map.
    static func template(_ params: JSONValue) throws -> PSDDescriptor {
        guard let raw = params[templateKey] else { throw PCIOError.unsupported("a Displace map from a file or document is not written to PSD") }
        guard let hex = raw.stringValue else { throw PCIOError.corrupt("the Displace PSD data must be hex text") }
        if hex.utf8.count > maxTemplateBytes * 2 { throw PCIOError.corrupt("the Displace PSD data is too large") }
        guard let bytes = SmartMap.fromHex(hex) else { throw PCIOError.corrupt("the Displace PSD data is not valid hex") }
        let item: PSDDescriptor
        do { item = try PSDDescriptor(bytes: bytes) } catch { throw PCIOError.corrupt("the Displace PSD data is unreadable (\(error))") }
        if !item.classID.is("filterFX") || SmartMap.int(item, "filterID") != filterID || fltrMap(item) == nil {
            throw PCIOError.corrupt("the Displace PSD data is not a Displace filter with an embedded map")
        }
        return item
    }

    /// The `filterFXList` item: the template with the current scales, fit and undefined areas.
    static func exportItem(_ params: JSONValue) throws -> PSDDescriptor {
        guard let object = params.objectValue else { throw PCIOError.unsupported("Displace parameters must be an object") }
        let editable = ["horizontal", "vertical", "fit", "undefinedAreas"]
        if let k = object.keys.sorted().first(where: { !SmartMap.isMeta($0) && !editable.contains($0) }) {
            throw PCIOError.unsupported("Displace setting `\(k)` has no PSD equivalent next to its embedded map")
        }
        var item = try template(params)
        guard var f = SmartMap.getDesc(item, "Fltr") else { throw PCIOError.corrupt("the Displace PSD data has no filter") }
        func scale(_ k: String, _ d: Double) throws -> DValue {
            let v: Double? = if let p = params[k] { p.doubleValue } else { d }
            guard let v, v.isFinite else { throw PCIOError.unsupported("Displace `\(k)` must be a number") }
            return .integer(Int32(min(max(v.rounded(), -999), 999)))
        }
        func choice(_ k: String, _ table: [(code: String, name: String)], _ d: String) throws -> DID {
            let v: String? = if let p = params[k] { p.stringValue } else { d }
            guard let v else { throw PCIOError.unsupported("Displace `\(k)` must be text") }
            guard let code = table.first(where: { $0.name == v })?.code else {
                throw PCIOError.unsupported("Displace `\(k)` is not one of the PSD values")
            }
            return DID(code)
        }
        // Keep the template's enum types; only the values change.
        func setEnum(_ f: inout PSDDescriptor, _ key: String, _ value: DID) {
            let type: DID = if case let .enumerated(t, _)? = f[key] { t } else { DID(key) }
            SmartMap.set(&f, key, .enumerated(type: type, value: value))
        }
        SmartMap.set(&f, "HrzS", try scale("horizontal", 10))
        SmartMap.set(&f, "VrtS", try scale("vertical", 10))
        setEnum(&f, "DspM", try choice("fit", fits, "stretch"))
        setEnum(&f, "UndA", try choice("undefinedAreas", undefined, "repeat"))
        SmartMap.set(&item, "Fltr", .descriptor(f))
        return item
    }

    /// The displacement map embedded in Displace params imported from PSD (nil when there is none
    /// or it is unreadable). The two planes become the first two channels; identical planes (every
    /// file seen so far) become one channel, which Displace reads for both directions.
    public static func embeddedMap(_ params: JSONValue) -> FloatImage? {
        guard let item = try? template(params), let m = fltrMap(item),
              let w = Int32(exactly: m.width), let h = Int32(exactly: m.height) else { return nil }
        let rect = PixelRect(x0: 0, y0: 0, x1: w, y1: h)
        func v(_ b: UInt8) -> Float { Float(b) / 255 }
        if m.horizontal.elementsEqual(m.vertical) {
            return FloatImage(rect: rect, channels: 1, data: m.horizontal.map(v))
        }
        var data: [Float] = []
        data.reserveCapacity(m.width * m.height * 3)
        for (a, b) in zip(m.horizontal, m.vertical) { data += [v(a), v(b), 0.5] }
        return FloatImage(rect: rect, channels: 3, data: data)
    }
}
