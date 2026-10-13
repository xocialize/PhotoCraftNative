// Port of photocraft-io (crates/io/src/smart_map.rs), MIT OR Apache-2.0, © ArtCraft Team and the
// PhotoCraft contributors.
//
// Smart objects in PSD: the placed-layer blocks (`SoLd`, `PlLd`) and the smart filter stack
// (`filterFX` inside `SoLd`).
//
// Layouts follow the Adobe PSD spec ("Placed Layer", "Placed Layer Data") and Photoshop-authored
// files (`corpus/photoshop/smart-filters`): a `soLD` descriptor holds the linked-file id (`Idnt`,
// the uuid of the `lnk2` item), the instance id (`placed`, which keys the `FEid` filter cache),
// the transform quad (`Trnf`), the source size (`Sz  `), the warp, and when filters are applied a
// `filterFX` object:
//
//     filterFX (filterFXStyle): enab, validAtPosition, filterMaskEnable, filterMaskLinked,
//       filterMaskExtendWithWhite, filterFXList = [ filterFX: Nm, blendOptions {Opct, Md},
//       enab, hasoptions, FrgC, BckC, Fltr (the filter's own descriptor), filterID ]
//
// The list is in application order (first = bottom, applied first), like
// `SmartObject.smartFilters`. Filters PhotoCraft implements map to their command id and dialog
// parameters; any other filter becomes an `unsupportedFilter` entry that keeps its descriptor
// verbatim (hex in `params.psd`), so it is listed, can be hidden, reordered or deleted, and is
// written back unchanged.
//
// Camera Raw and Displace keep their whole item as a template next to the editable settings
// (Displace's carries the embedded displacement map, see `DisplaceMap.swift`).
//
// This file holds the filter mapping; the placed-layer blocks, the `FEid` filter mask and
// `uuidFrom` are in `SmartPlaced.swift`.

import Foundation
import PCDocument
import PCFoundation
import PCIOCore
import PCPSD

public enum SmartMap {
    /// Command id of a Photoshop smart filter PhotoCraft does not implement. Its params hold the
    /// filter's name, Photoshop filter id and descriptor (`psd`, hex); it renders as a pass-through.
    public static let unsupportedFilter = "psd.unsupportedFilter"

    /// The smart filter stack of a placed layer, as stored in `filterFX`.
    public struct FilterStack: Equatable, Sendable {
        /// `enab`: Layer › Smart Filter › Disable Smart Filters clears it.
        public var enabled: Bool
        public var filters: [SmartFilter]
        /// `filterMaskEnable`.
        public var maskEnabled: Bool
        /// `filterMaskLinked`.
        public var maskLinked: Bool

        /// photocraft's `Default`: enabled, no filters, mask enabled and unlinked.
        public init() {
            enabled = true
            filters = []
            maskEnabled = true
            maskLinked = false
        }

        public init(enabled: Bool = true, filters: [SmartFilter], maskEnabled: Bool = true, maskLinked: Bool = false) {
            self.enabled = enabled
            self.filters = filters
            self.maskEnabled = maskEnabled
            self.maskLinked = maskLinked
        }
    }

    /// What a `soLD` descriptor says about a smart object.
    public struct Placed: Equatable, Sendable {
        public var descriptor: PSDDescriptor
        /// `Idnt`: uuid of the embedded or linked file (`lnk2` item).
        public var idnt: String
        /// `placed`: id of this instance (keys the `FEid` filter cache).
        public var placed: String
        /// Source pixels → document pixels (from `Trnf` and `Sz  `).
        public var transform: PCAffine
        /// `filterFX`, if any filters were ever applied.
        public var stack: FilterStack?

        public init(descriptor: PSDDescriptor, idnt: String, placed: String, transform: PCAffine, stack: FilterStack?) {
            self.descriptor = descriptor
            self.idnt = idnt
            self.placed = placed
            self.transform = transform
            self.stack = stack
        }
    }

    // MARK: - Small descriptor helpers (shared with the Camera Raw and Displace maps)

    static func textOf(_ d: PSDDescriptor, _ key: String) -> String? { Blocks.textOf(d, key) }

    static func getDesc(_ d: PSDDescriptor, _ key: String) -> PSDDescriptor? { Blocks.getDesc(d, key) }

    static func boolOr(_ d: PSDDescriptor, _ key: String, _ fallback: Bool) -> Bool {
        if case let .boolean(b)? = d[key] { return b }
        return fallback
    }

    /// A finite number (`doub`, `UntF`, `long`).
    static func px(_ d: PSDDescriptor, _ key: String) -> Double? {
        guard let v = Blocks.num(d[key]), v.isFinite else { return nil }
        return v
    }

    /// A `long`.
    static func int(_ d: PSDDescriptor, _ key: String) -> Int32? {
        if case let .integer(i)? = d[key] { return i }
        return nil
    }

    static func intValue(_ v: DValue) -> Int32? {
        if case let .integer(i) = v { return i }
        return nil
    }

    /// A four-character code as Photoshop's `filterID` integer (big-endian).
    static func code(_ c: String) -> Int32 { Int32(bitPattern: FourCC(c).rawValue) }

    /// Replaces item `key` in place, or appends it (photocraft `set`).
    static func set(_ d: inout PSDDescriptor, _ key: String, _ v: DValue) { d.set(key, v) }

    /// The message of an error thrown by this module (photocraft's `String` errors).
    static func message(_ e: any Error) -> String {
        switch e {
        case let PCIOError.unsupported(m), let PCIOError.corrupt(m): m
        default: String(describing: e)
        }
    }

    // MARK: - Reading

    /// The `soLD` descriptor of `SoLd`/`SoLE` block data.
    public static func soldDescriptor(_ data: [UInt8]) -> PSDDescriptor? {
        guard data.count >= 4, data[0 ..< 4].elementsEqual("soLD".utf8), data.count >= 8 else { return nil }
        return Blocks.parsePrefixVersioned(data, from: 8)
    }

    /// Parses `SoLd`/`SoLE` block data (best effort: nil when it is not a `soLD` structure).
    public static func parseSold(_ data: [UInt8]) -> Placed? {
        guard let d = soldDescriptor(data) else { return nil }
        let (idnt, transform) = Blocks.parseSmart("SoLd", data)
        let placed = textOf(d, "placed") ?? ""
        let stack = getDesc(d, "filterFX").map(filterStack)
        return Placed(descriptor: d, idnt: idnt, placed: placed, transform: transform, stack: stack)
    }

    /// Reads a `filterFX` object.
    public static func filterStack(_ fx: PSDDescriptor) -> FilterStack {
        var filters: [SmartFilter] = []
        if case let .list(items)? = fx["filterFXList"] {
            for v in items {
                if case let .descriptor(d) = v { filters.append(filterFromItem(d)) }
            }
        }
        return FilterStack(enabled: boolOr(fx, "enab", true), filters: filters, maskEnabled: boolOr(fx, "filterMaskEnable", true),
                           maskLinked: boolOr(fx, "filterMaskLinked", false))
    }

    // MARK: - The filters we model

    /// Photoshop filter → PhotoCraft command, keyed by the `Fltr` class (and `filterID`).
    struct Known: Sendable {
        let className: String
        let filterID: Int32
        /// `Nm  ` as Photoshop writes it (the menu item, with its ellipsis and mnemonic).
        let name: String
        let command: String
    }

    static let known: [Known] = [
        Known(className: "GsnB", filterID: code("GsnB"), name: "Gaussian Blur...", command: "filter.blur.gaussianBlur"),
        Known(className: "boxblur", filterID: 840, name: "Box Blur...", command: "filter.blur.boxBlur"),
        Known(className: "MtnB", filterID: code("MtnB"), name: "Motion Blur...", command: "filter.blur.motionBlur"),
        Known(className: "UnsM", filterID: code("UnsM"), name: "Unsharp Mask...", command: "filter.sharpen.unsharpMask"),
        Known(className: "AdNs", filterID: code("AdNs"), name: "Add Noise...", command: "filter.noise.addNoise"),
        Known(className: "Mdn ", filterID: code("Mdn "), name: "Median...", command: "filter.noise.median"),
        Known(className: "HghP", filterID: code("HghP"), name: "High Pass...", command: "filter.other.highPass"),
        Known(className: "Mxm ", filterID: code("Mxm "), name: "Maximum...", command: "filter.other.maximum"),
        Known(className: "Mnm ", filterID: code("Mnm "), name: "Minimum...", command: "filter.other.minimum"),
        Known(className: "Msc ", filterID: code("Msc "), name: "Mosaic...", command: "filter.pixelate.mosaic"),
        Known(className: "Embs", filterID: code("Embs"), name: "Emboss...", command: "filter.stylize.emboss"),
        Known(className: "Lvls", filterID: code("Lvls"), name: "Levels...", command: "image.adjustments.levels"),
        Known(className: "Crvs", filterID: code("Crvs"), name: "Curves...", command: "image.adjustments.curves"),
        // Shadows/Highlights at its defaults stores no `Fltr` (`hasoptions` false).
        Known(className: "adaptCorrect", filterID: 781, name: "Shado&ws/Highlights...", command: "image.adjustments.shadowsHighlights"),
    ]

    static func knownByCommand(_ command: String) -> Known? { known.first { $0.command == command } }

    /// RGB channel references in Levels/Curves (`Chnl` enum) and their parameter keys ("" = the
    /// composite: top-level keys).
    static let channels: [(code: String, key: String)] = [("Cmps", ""), ("Rd  ", "red"), ("Grn ", "green"), ("Bl  ", "blue")]

    static func channelKey(_ d: PSDDescriptor) -> String? {
        guard case let .reference(items)? = d["Chnl"], case let .enumerated(_, _, value)? = items.first else { return nil }
        return channels.first { value.bytes == Array($0.code.utf8) }?.key
    }

    static func adjustmentList(_ d: PSDDescriptor) -> [PSDDescriptor]? {
        guard case let .list(items)? = d["Adjs"] else { return nil }
        var out: [PSDDescriptor] = []
        for v in items {
            guard case let .descriptor(x) = v else { return nil }
            out.append(x)
        }
        return out
    }

    static func levelsParams(_ f: PSDDescriptor) -> JSONValue? {
        guard let adjs = adjustmentList(f) else { return nil }
        var out: [String: JSONValue] = [:]
        for a in adjs {
            guard let key = channelKey(a) else { return nil }
            var o: [String: JSONValue] = [:]
            func pair(_ k: String) -> (Int32, Int32)? {
                guard case let .list(v)? = a[k], v.count == 2, let lo = intValue(v[0]), let hi = intValue(v[1]) else { return nil }
                return (lo, hi)
            }
            if let (lo, hi) = pair("Inpt") {
                o["inBlack"] = .number(Double(lo))
                o["inWhite"] = .number(Double(hi))
            }
            if let g = px(a, "Gmm ") { o["gamma"] = .number(g) }
            if let (lo, hi) = pair("Otpt") {
                o["outBlack"] = .number(Double(lo))
                o["outWhite"] = .number(Double(hi))
            }
            if key.isEmpty {
                out.merge(o) { _, new in new }
            } else {
                out[key] = .object(o)
            }
        }
        return .object(out)
    }

    static func curvesParams(_ f: PSDDescriptor) -> JSONValue? {
        guard let adjs = adjustmentList(f) else { return nil }
        var out: [String: JSONValue] = [:]
        for a in adjs {
            guard let key = channelKey(a) else { return nil }
            // A pencil-drawn curve is a mapping of 256 output levels (`Mpng`) instead of points.
            if case let .list(map)? = a["Mpng"] {
                var levels: [JSONValue] = []
                for v in map {
                    guard let o = intValue(v) else { return nil }
                    levels.append(.number(Double(min(max(o, 0), 255))))
                }
                guard levels.count == 256 else { return nil }
                out[key.isEmpty ? "points" : key] = .array(levels)
                out["pencil"] = .bool(true)
                continue
            }
            guard case let .list(pts)? = a["Crv "] else { return nil }
            var points: [JSONValue] = []
            for p in pts {
                guard case let .descriptor(p) = p, let x = px(p, "Hrzn"), let y = px(p, "Vrtc") else { return nil }
                points.append(.array([.number(x), .number(y)]))
            }
            out[key.isEmpty ? "points" : key] = .array(points)
        }
        return .object(out)
    }

    /// Our command and parameters for a known Photoshop filter; nil when the filter (or one of its
    /// settings) is not modelled.
    static func knownParams(_ className: String, _ f: PSDDescriptor?) -> (command: String, params: JSONValue)? {
        guard let k = known.first(where: { $0.className == className }) else { return nil }
        let params: JSONValue
        guard let f else {
            if className == "adaptCorrect" { return (k.command, .object([:])) }
            return nil
        }
        switch className {
        case "GsnB", "boxblur", "Mdn ", "HghP", "Mxm ", "Mnm ":
            guard let r = px(f, "Rds ") else { return nil }
            params = ["radius": .number(r)]
        case "MtnB":
            guard let a = int(f, "Angl"), let d = px(f, "Dstn") else { return nil }
            params = ["angle": .number(Double(a)), "distance": .number(d)]
        case "UnsM":
            guard let a = px(f, "Amnt"), let r = px(f, "Rds "), let t = int(f, "Thsh") else { return nil }
            params = ["amount": .number(a), "radius": .number(r), "threshold": .number(Double(t))]
        case "AdNs":
            let dist: String
            switch Blocks.enumBytes(f, "Dstr") {
            case Array("Unfr".utf8)?: dist = "uniform"
            case Array("Gsn ".utf8)?: dist = "gaussian"
            default: return nil
            }
            guard case let .boolean(mono)? = f["Mnch"], let amount = px(f, "Nose") else { return nil }
            params = ["amount": .number(amount), "distribution": .string(dist), "monochromatic": .bool(mono),
                      "seed": .number(Double(int(f, "FlRs") ?? 0))]
        case "Msc ":
            guard let c = px(f, "ClSz") else { return nil }
            params = ["cellSize": .number(c)]
        case "Embs":
            guard let a = int(f, "Angl"), let h = int(f, "Hght"), let m = int(f, "Amnt") else { return nil }
            params = ["angle": .number(Double(a)), "height": .number(Double(h)), "amount": .number(Double(m))]
        case "Lvls":
            guard let p = levelsParams(f) else { return nil }
            params = p
        case "Crvs":
            guard let p = curvesParams(f) else { return nil }
            params = p
        default:
            return nil
        }
        return (k.command, params)
    }

    /// Lowercase hex of `bytes`.
    static func toHex(_ bytes: [UInt8]) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var out = [UInt8](repeating: 0, count: bytes.count * 2)
        for (i, b) in bytes.enumerated() {
            out[2 * i] = digits[Int(b >> 4)]
            out[2 * i + 1] = digits[Int(b & 15)]
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Bytes of hex text (either case); nil for an odd length or a non-hex digit.
    static func fromHex(_ s: String) -> [UInt8]? {
        func parse(_ b: UnsafeBufferPointer<UInt8>) -> [UInt8]? {
            guard b.count % 2 == 0 else { return nil }
            func digit(_ c: UInt8) -> UInt8? {
                switch c {
                case 48 ... 57: c - 48
                case 97 ... 102: c - 87
                case 65 ... 70: c - 55
                default: nil
                }
            }
            var out = [UInt8](repeating: 0, count: b.count / 2)
            for i in 0 ..< out.count {
                guard let hi = digit(b[2 * i]), let lo = digit(b[2 * i + 1]) else { return nil }
                out[i] = hi << 4 | lo
            }
            return out
        }
        if let r = s.utf8.withContiguousStorageIfAvailable(parse) { return r }
        return Array(s.utf8).withUnsafeBufferPointer(parse)
    }

    /// The neutral blending a stored template carries (the model's own fields replace it on
    /// export), so hiding or re-blending a filter leaves its params alone.
    static let neutralFilter = SmartFilter(command: "", params: .null, blend: .normal, opacity: 1, visible: true)

    /// One `filterFXList` item → `SmartFilter` (an `unsupportedFilter` when not modelled).
    public static func filterFromItem(_ item: PSDDescriptor) -> SmartFilter {
        let opts = getDesc(item, "blendOptions")
        let opacity = opts.flatMap { px($0, "Opct") }.map { Float(min(max($0 / 100, 0), 1)) } ?? 1
        let blend = opts.flatMap { Blocks.enumOf($0, "Md  ") }.flatMap(Blocks.blendFromId) ?? .normal
        let visible = boolOr(item, "enab", true)
        let fltr = getDesc(item, "Fltr")
        let filterID = int(item, "filterID") ?? 0
        let className = fltr.map(\.classID.name) ?? known.first(where: { $0.filterID == filterID })?.className
        let mapped: (command: String, params: JSONValue)? = switch className {
        case CameraRawMap.className?: CameraRawMap.importParams(item).map { (CameraRawMap.command, $0) }
        case DisplaceMap.className?: DisplaceMap.importParams(item).map { (DisplaceMap.command, $0) }
        case let c?: knownParams(c, fltr)
        case nil: nil
        }
        let command: String, params: JSONValue
        if let mapped {
            (command, params) = mapped
        } else {
            let name = textOf(item, "Nm  ") ?? ""
            // The stored descriptor carries neutral blending (the model's own fields replace them
            // on export), so hiding or re-blending the filter leaves its params alone.
            var neutral = item
            for i in neutral.items.indices {
                if neutral.items[i].key.is("blendOptions") {
                    neutral.items[i].value = blendOptions(neutralFilter)
                } else if neutral.items[i].key.is("enab") {
                    neutral.items[i].value = .boolean(true)
                }
            }
            command = unsupportedFilter
            params = ["name": .string(name.replacingOccurrences(of: "&", with: "")), "filterID": .number(Double(filterID)),
                      "psd": .string(toHex(neutral.serializedBytes()))]
        }
        return SmartFilter(command: command, params: params, blend: blend, opacity: opacity, visible: visible)
    }

    // MARK: - Writing

    static func unit(_ u: String, _ v: Double) -> DValue { .unitFloat(unit: FourCC(u), value: v) }

    static func rgbc(_ v: Double) -> DValue {
        .descriptor(PSDDescriptor(classID: "RGBC").with("Rd  ", .double(v)).with("Grn ", .double(v)).with("Bl  ", .double(v)))
    }

    static func blendOptions(_ f: SmartFilter) -> DValue {
        let opacity = f.opacity.isFinite ? Double(min(max(f.opacity, 0), 1)) * 100 : 100
        return .descriptor(PSDDescriptor(classID: "blendOptions").with("Opct", unit("#Prc", opacity)).with("Md  ", Blocks.blendLongValue(f.blend)))
    }

    /// Parameter keys that are bookkeeping, not filter settings.
    static func isMeta(_ k: String) -> Bool { k == "layer" || k.hasPrefix("__") }

    static func pf(_ p: JSONValue, _ key: String, _ fallback: Double) -> Double {
        if let v = p[key]?.doubleValue, v.isFinite { return v }
        return fallback
    }

    static func pi(_ p: JSONValue, _ key: String, _ fallback: Double) -> DValue { .integer(roundCast(pf(p, key, fallback))) }

    static func channelRef(_ code: String) -> DValue {
        .reference([.enumerated(PSDDescriptor.ClassRef(name: PSDUnicodeString.nulTerminated(""), classID: "Chnl"), type: "Chnl",
                                value: .code(FourCC(code)))])
    }

    /// The `Adjs` entries of a Levels or Curves filter: the composite first, then red, green, blue.
    static func adjustments(_ p: JSONValue, curves: Bool) throws -> DValue {
        guard let obj = p.objectValue else { throw PCIOError.unsupported("parameters are not an object") }
        let allowed: [String] = curves ? ["points", "red", "green", "blue", "pencil"]
            : ["inBlack", "inWhite", "gamma", "outBlack", "outWhite", "red", "green", "blue"]
        if let k = obj.keys.sorted().first(where: { !isMeta($0) && !allowed.contains($0) }) {
            throw PCIOError.unsupported("setting `\(k)` has no PSD equivalent")
        }
        var list: [DValue] = []
        for (code, key) in channels {
            guard let o = key.isEmpty ? p : p[key] else { continue }
            var a = PSDDescriptor(classID: DID(curves ? "CrvA" : "LvlA")).with("Chnl", channelRef(code))
            if curves {
                let src = key.isEmpty ? p["points"] : o
                guard let pts = src?.arrayValue else { continue }
                if p["pencil"]?.boolValue == true {
                    var map: [DValue] = []
                    for v in pts {
                        guard let x = v.doubleValue, x.isFinite else {
                            throw PCIOError.unsupported("a pencil-drawn curve is not 256 output levels")
                        }
                        map.append(.integer(Int32(min(max(x.rounded(), 0), 255))))
                    }
                    guard map.count == 256 else { throw PCIOError.unsupported("a pencil-drawn curve is not 256 output levels") }
                    a = a.with("Mpng", .list(map))
                    list.append(.descriptor(a))
                    continue
                }
                var points: [DValue] = []
                for q in pts {
                    guard let x = q[0]?.doubleValue, x.isFinite, let y = q[1]?.doubleValue, y.isFinite else {
                        throw PCIOError.unsupported("a curve point is not [input, output]")
                    }
                    points.append(.descriptor(PSDDescriptor(classID: "Pnt ").with("Hrzn", .double(x)).with("Vrtc", .double(y))))
                }
                a = a.with("Crv ", .list(points))
            } else {
                if key.isEmpty && !["inBlack", "inWhite", "gamma", "outBlack", "outWhite"].contains(where: { o[$0] != nil }) { continue }
                a = a.with("Inpt", .list([pi(o, "inBlack", 0), pi(o, "inWhite", 255)])).with("Gmm ", .double(pf(o, "gamma", 1)))
                if o["outBlack"] != nil || o["outWhite"] != nil {
                    a = a.with("Otpt", .list([pi(o, "outBlack", 0), pi(o, "outWhite", 255)]))
                }
            }
            list.append(.descriptor(a))
        }
        return .list(list)
    }

    /// The `Fltr` descriptor of a modelled filter (nil = written without options).
    static func fltrFor(_ k: Known, _ p: JSONValue) throws -> PSDDescriptor? {
        let d = PSDDescriptor(classID: DID(k.className))
        switch k.className {
        case "GsnB", "boxblur", "Mdn ", "HghP", "Mxm ", "Mnm ":
            if p["preserve"]?.stringValue == "roundness" { throw PCIOError.unsupported("“preserve roundness” has no PSD equivalent") }
            return d.with("Rds ", unit("#Pxl", pf(p, "radius", 1)))
        case "MtnB":
            return d.with("Angl", pi(p, "angle", 0)).with("Dstn", unit("#Pxl", pf(p, "distance", 10)))
        case "UnsM":
            return d.with("Amnt", unit("#Prc", pf(p, "amount", 50))).with("Rds ", unit("#Pxl", pf(p, "radius", 1))).with("Thsh", pi(p, "threshold", 0))
        case "AdNs":
            let gauss = p["distribution"]?.stringValue == "gaussian"
            return d.with("Dstr", .enumerated(type: "Dstr", value: DID(gauss ? "Gsn " : "Unfr")))
                .with("Nose", unit("#Prc", pf(p, "amount", 12.5)))
                .with("Mnch", .boolean(p["monochromatic"]?.boolValue ?? false))
                .with("FlRs", pi(p, "seed", 0))
        case "Msc ":
            return d.with("ClSz", unit("#Pxl", pf(p, "cellSize", 10)))
        case "Embs":
            return d.with("Angl", pi(p, "angle", 135)).with("Hght", pi(p, "height", 3)).with("Amnt", pi(p, "amount", 100))
        case "Lvls":
            return d.with("Adjs", try adjustments(p, curves: false))
        case "Crvs":
            return d.with("Adjs", try adjustments(p, curves: true))
        case "adaptCorrect":
            if let o = p.objectValue, o.keys.contains(where: { !isMeta($0) }) {
                throw PCIOError.unsupported("only default Shadows/Highlights settings are written to PSD")
            }
            return nil
        default:
            throw PCIOError.unsupported("not a recognized filter")
        }
    }

    /// The `filterFXList` item for one smart filter, or why it can't be written.
    public static func itemForFilter(_ f: SmartFilter) throws -> PSDDescriptor {
        if f.command == CameraRawMap.command {
            var d = try CameraRawMap.exportItem(f.params)
            set(&d, "blendOptions", blendOptions(f))
            set(&d, "enab", .boolean(f.visible))
            return d
        }
        if f.command == DisplaceMap.command {
            var d = try DisplaceMap.exportItem(f.params)
            set(&d, "blendOptions", blendOptions(f))
            set(&d, "enab", .boolean(f.visible))
            return d
        }
        if f.command == unsupportedFilter {
            guard let hex = f.params["psd"]?.stringValue, let raw = fromHex(hex) else {
                throw PCIOError.corrupt("its filter data is missing")
            }
            var d: PSDDescriptor
            do { d = try PSDDescriptor(bytes: raw) } catch { throw PCIOError.corrupt("its filter data is unreadable (\(error))") }
            set(&d, "blendOptions", blendOptions(f))
            set(&d, "enab", .boolean(f.visible))
            return d
        }
        guard let k = knownByCommand(f.command) else { throw PCIOError.unsupported("this filter has no PSD equivalent") }
        let fltr = try fltrFor(k, f.params)
        var d = PSDDescriptor(classID: "filterFX")
            .with("Nm  ", .text(.nulTerminated(k.name)))
            .with("blendOptions", blendOptions(f))
            .with("enab", .boolean(f.visible))
            .with("hasoptions", .boolean(fltr != nil))
            .with("FrgC", rgbc(0))
            .with("BckC", rgbc(255))
        if let fltr { d = d.with("Fltr", .descriptor(fltr)) }
        return d.with("filterID", .integer(k.filterID))
    }

    /// Builds a `filterFX` object; filters that can't be written are left out, with a message each.
    public static func filterFX(_ stack: FilterStack, _ layer: String, _ warnings: inout [String]) -> PSDDescriptor {
        var list: [DValue] = []
        for f in stack.filters {
            do {
                list.append(.descriptor(try itemForFilter(f)))
            } catch {
                warnings.append("layer \"\(layer)\": smart filter \(f.command) was not written to PSD: \(message(error))")
            }
        }
        return PSDDescriptor(classID: "filterFXStyle")
            .with("enab", .boolean(stack.enabled))
            .with("validAtPosition", .boolean(true))
            .with("filterMaskEnable", .boolean(stack.maskEnabled))
            .with("filterMaskLinked", .boolean(stack.maskLinked))
            .with("filterMaskExtendWithWhite", .boolean(true))
            .with("filterFXList", .list(list))
    }

    /// The displacement map embedded in Displace params imported from PSD (nil when there is none
    /// or it is unreadable); see `DisplaceMap.embeddedMap`.
    public static func displaceEmbeddedMap(_ params: JSONValue) -> FloatImage? { DisplaceMap.embeddedMap(params) }
}
