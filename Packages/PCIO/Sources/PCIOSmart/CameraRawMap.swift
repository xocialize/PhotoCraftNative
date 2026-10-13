// Port of photocraft-io (crates/io/src/camera_raw_map.rs), with the serde shape of photocraft-algo's
// `CameraRaw` settings (crates/algo/src/camera_raw.rs: `CameraRaw`, `Wheel`, `validate`,
// `validate_curve`, `MAX_CURVE_POINTS`) mirrored locally; MIT OR Apache-2.0, © ArtCraft Team and the
// PhotoCraft contributors.
//
// Camera Raw Filter descriptors observed in real PSD files (filter version 18.4, process 6).
// Verified develop controls are editable. Other processing versions or settings retain the entire
// filter through the existing opaque-filter path.

import Foundation
import PCDocument
import PCIOCore
import PCPSD

public enum CameraRawMap {
    static let className = "Adobe Camera Raw Filter"
    /// The PhotoCraft command of a Camera Raw smart filter.
    public static let command = "filter.cameraRaw"
    static let filterID: Int32 = 2783
    /// The params key holding the whole PSD item (hex).
    public static let templateKey = "__cameraRawPsd"
    static let maxTemplateBytes = 1024 * 1024

    // Exposure and sharpening radius are doubles; other observed controls are integer levels.
    static let scalars: [(param: String, key: String)] = [
        ("temperature", "Temp"), ("tint", "Tint"), ("exposure", "Ex12"), ("contrast", "Cr12"), ("highlights", "Hi12"),
        ("shadows", "Sh12"), ("whites", "Wh12"), ("blacks", "Bk12"), ("texture", "CrTx"), ("clarity", "Cl12"),
        ("dehaze", "Dhze"), ("vibrance", "Vibr"), ("saturation", "Strt"), ("curveShadows", "PC_S"), ("curveDarks", "PC_D"),
        ("curveLights", "PC_L"), ("curveHighlights", "PC_H"), ("sharpenAmount", "Shrp"), ("sharpenRadius", "ShpR"),
        ("sharpenDetail", "ShpD"), ("sharpenMasking", "ShpM"), ("noiseLuminance", "LNR "), ("noiseLuminanceDetail", "LNRD"),
        ("noiseColor", "CNR "), ("noiseColorDetail", "CNRD"), ("gradeShadows.hue", "STSH"), ("gradeShadows.sat", "STSS"),
        ("gradeShadows.lum", "CgSL"), ("gradeMidtones.hue", "CgMH"), ("gradeMidtones.sat", "CgMS"), ("gradeMidtones.lum", "CgML"),
        ("gradeHighlights.hue", "STHH"), ("gradeHighlights.sat", "STHS"), ("gradeHighlights.lum", "CgHL"),
        ("gradeGlobal.hue", "CgGH"), ("gradeGlobal.sat", "CgGS"), ("gradeGlobal.lum", "CgGL"), ("gradeBlending", "CgBl"),
        ("gradeBalance", "STB "), ("grainAmount", "GRNA"), ("grainSize", "GRNS"), ("grainRoughness", "GRNF"),
        ("vignetteAmount", "PCVA"), ("vignetteMidpoint", "PCVM"), ("vignetteFeather", "PCVF"), ("vignetteRoundness", "PCVR"),
    ]
    static let arrays: [(param: String, keys: [String])] = [
        ("curveSplits", ["PC_1", "PC_2", "PC_3"]),
        ("hslHue", ["HA_R", "HA_O", "HA_Y", "HA_G", "HA_A", "HA_B", "HA_P", "HA_M"]),
        ("hslSat", ["SA_R", "SA_O", "SA_Y", "SA_G", "SA_A", "SA_B", "SA_P", "SA_M"]),
        ("hslLum", ["LA_R", "LA_O", "LA_Y", "LA_G", "LA_A", "LA_B", "LA_P", "LA_M"]),
    ]
    static let curves: [(param: String, key: String)] = [
        ("pointCurve", "Crv "), ("pointCurveRed", "CrvR"), ("pointCurveGreen", "CrvG"), ("pointCurveBlue", "CrvB"),
    ]

    // These controls have no PhotoCraft counterpart yet. Their observed neutral values can be
    // retained in the template; active values must keep the entire filter opaque.
    static let neutralOnly: [(key: String, neutral: Int32)] = [
        ("LNRC", 0), ("CNRS", 50), ("MDis", 0), ("VigA", 0), ("VigM", 50), ("crfs", 100), ("TMMs", 0), ("PGTM", 0), ("RGBt", 0),
    ]

    static func defaultParams() -> JSONValue { CameraRawSettings().json }

    static func knownKey(_ key: String) -> Bool {
        ["CrVe", "PrVN", "PrVe", "WBal"].contains(key) || scalars.contains { $0.key == key } || arrays.contains { $0.keys.contains(key) }
            || curves.contains { $0.key == key } || neutralOnly.contains { $0.key == key }
    }

    /// `name` or `wheel.field`.
    static func getParam(_ params: JSONValue, _ name: String) -> JSONValue? {
        if let dot = name.firstIndex(of: ".") {
            return params[String(name[..<dot])]?[String(name[name.index(after: dot)...])]
        }
        return params[name]
    }

    /// Replaces an existing `name` or `wheel.field` (photocraft `*get_param_mut(..)? = v`); false
    /// when it is not there.
    static func setParam(_ params: inout JSONValue, _ name: String, _ value: JSONValue) -> Bool {
        guard case var .object(o) = params else { return false }
        if let dot = name.firstIndex(of: ".") {
            let (wheel, field) = (String(name[..<dot]), String(name[name.index(after: dot)...]))
            guard case var .object(w)? = o[wheel], w[field] != nil else { return false }
            w[field] = value
            o[wheel] = .object(w)
        } else {
            guard o[name] != nil else { return false }
            o[name] = value
        }
        params = .object(o)
        return true
    }

    /// Replaces element `index` of the existing array `name`; false when it is not there.
    static func setElement(_ params: inout JSONValue, _ name: String, _ index: Int, _ value: JSONValue) -> Bool {
        guard case var .object(o) = params, case var .array(a)? = o[name], a.indices.contains(index) else { return false }
        a[index] = value
        o[name] = .array(a)
        params = .object(o)
        return true
    }

    static func numberRange(_ key: String) -> ClosedRange<Double> {
        switch key {
        case "Ex12": -5.0 ... 5.0
        case "ShpR": 0.5 ... 3.0
        case "Shrp": 0.0 ... 150.0
        case "STSH", "STHH", "CgMH", "CgGH": 0.0 ... 360.0
        case "PC_1", "PC_2", "PC_3", "ShpD", "ShpM", "LNR ", "LNRD", "CNR ", "CNRD", "STSS", "STHS", "CgMS", "CgGS", "CgBl", "GRNA", "GRNS",
             "GRNF", "PCVM", "PCVF": 0.0 ... 100.0
        default: -100.0 ... 100.0
        }
    }

    static func isDoubleKey(_ key: String) -> Bool { key == "Ex12" || key == "ShpR" }

    static func readNumber(_ d: PSDDescriptor, _ key: String) -> Double? {
        let value: Double
        switch d[key] {
        case let .double(v)? where isDoubleKey(key): value = v
        case let .integer(v)? where !isDoubleKey(key): value = Double(v)
        default: return nil
        }
        return value.isFinite && numberRange(key).contains(value) ? value : nil
    }

    static func readCurve(_ value: DValue) -> JSONValue? {
        guard case let .list(values) = value, values.count >= 4, values.count % 2 == 0,
              values.count <= CameraRawSettings.maxCurvePoints * 2 else { return nil }
        var points: [[Float]] = []
        for i in stride(from: 0, to: values.count, by: 2) {
            guard case let .integer(x) = values[i], case let .integer(y) = values[i + 1] else { return nil }
            points.append([Float(x), Float(y)])
        }
        if CameraRawSettings.validateCurve(points) != nil { return nil }
        if points == [[0, 0], [255, 255]] { return .array([]) }
        return CameraRawSettings.curveJSON(points)
    }

    static func descriptorParams(_ d: PSDDescriptor) -> JSONValue? {
        guard d.classID.is(className) else { return nil }
        switch (SmartMap.int(d, "PrVN"), SmartMap.int(d, "PrVe")) {
        case (5?, 184_549_376?), (6?, 251_920_384?): break
        default: return nil
        }
        guard case .text? = d["CrVe"] else { return nil }
        // A partial decode would omit active processing (masks, profiles, HDR or other settings)
        // when the layer is re-rendered. Keep such a filter opaque instead.
        if d.items.contains(where: { !knownKey($0.key.name) }) { return nil }
        if let w = d["WBal"] {
            guard case let .enumerated(t, v) = w, t.is("WBal"), v.is("Cst ") else { return nil }
        }
        if neutralOnly.contains(where: { d[$0.key] != nil && SmartMap.int(d, $0.key) != $0.neutral }) { return nil }
        var params = defaultParams()
        for (param, key) in scalars where d[key] != nil {
            guard let v = readNumber(d, key), setParam(&params, param, .number(v)) else { return nil }
        }
        for (param, key) in curves {
            if let value = d[key] {
                guard let c = readCurve(value), setParam(&params, param, c) else { return nil }
            }
        }
        for (param, keys) in arrays {
            for (index, key) in keys.enumerated() where d[key] != nil {
                guard let v = readNumber(d, key), setElement(&params, param, index, .number(v)) else { return nil }
            }
        }
        if validateSplits(params) != nil { return nil }
        // Use the same Float representation as the editor so opening and confirming without
        // changes does not rewrite a stored double such as 1.15 to 1.149999976158142.
        guard let typed = try? CameraRawSettings(json: params) else { return nil }
        return typed.json
    }

    static func importParams(_ item: PSDDescriptor) -> JSONValue? {
        guard SmartMap.int(item, "filterID") == filterID, let f = SmartMap.getDesc(item, "Fltr"),
              case var .object(params)? = descriptorParams(f) else { return nil }
        var template = item
        SmartMap.set(&template, "blendOptions", SmartMap.blendOptions(SmartMap.neutralFilter))
        SmartMap.set(&template, "enab", .boolean(true))
        let bytes = template.serializedBytes()
        if bytes.count > maxTemplateBytes { return nil }
        params[templateKey] = .string(SmartMap.toHex(bytes))
        return .object(params)
    }

    /// Why `curveSplits` is not three strictly increasing percentages, or nil.
    static func validateSplits(_ params: JSONValue) -> String? {
        guard let values = params["curveSplits"]?.arrayValue, values.count == 3 else { return "curveSplits must contain three numbers" }
        var previous = -1.0
        for value in values {
            guard let v = value.doubleValue, v.isFinite, (0.0 ... 100.0).contains(v) else { return "curve splits must be finite percentages" }
            if v <= previous { return "curve splits must be strictly increasing" }
            previous = v
        }
        return nil
    }

    static func supportedParam(_ key: String) -> Bool {
        scalars.contains { $0.param.split(separator: ".").first.map(String.init) == key } || arrays.contains { $0.param == key }
            || curves.contains { $0.param == key }
    }

    static func writeNumber(_ d: inout PSDDescriptor, _ key: String, _ value: JSONValue) throws {
        guard let number = value.doubleValue, number.isFinite else { throw PCIOError.unsupported("Camera Raw \(key) must be finite") }
        guard numberRange(key).contains(number) else { throw PCIOError.unsupported("Camera Raw \(key) is outside the supported range") }
        // PSD stores these as integer slider levels; PhotoCraft's sliders are continuous. Rounding
        // (at most half a level) keeps the filter instead of leaving it out of the PSD.
        // Hue 360 is the same angle as 0.
        let v: DValue = switch key {
        case "Ex12", "ShpR": .double(number)
        case "STSH", "STHH", "CgMH", "CgGH": .integer(roundCast(number) % 360)
        default: .integer(roundCast(number))
        }
        SmartMap.set(&d, key, v)
    }

    static func exportItem(_ params: JSONValue) throws -> PSDDescriptor {
        guard let object = params.objectValue else { throw PCIOError.unsupported("Camera Raw parameters must be an object") }
        let defaults = defaultParams()
        for key in object.keys.sorted() where key != "layer" && !key.hasPrefix("__") && defaults[key] == nil {
            throw PCIOError.unsupported("Camera Raw setting `\(key)` has no verified PSD mapping")
        }
        for wheel in ["gradeShadows", "gradeMidtones", "gradeHighlights", "gradeGlobal"] {
            if let w = params[wheel]?.objectValue, w.keys.contains(where: { !["hue", "sat", "lum"].contains($0) }) {
                throw PCIOError.unsupported("Camera Raw `\(wheel)` contains an unknown wheel setting")
            }
        }
        // Bound variable-sized curves before decoding allocates their point arrays.
        for (param, _) in curves {
            if let a = params[param]?.arrayValue, a.count > CameraRawSettings.maxCurvePoints {
                throw PCIOError.unsupported("Camera Raw `\(param)` has too many points")
            }
        }
        var item: PSDDescriptor
        if let raw = object[templateKey] {
            guard let hex = raw.stringValue else { throw PCIOError.corrupt("Camera Raw PSD template must be hex text") }
            if hex.utf8.count > maxTemplateBytes * 2 { throw PCIOError.corrupt("Camera Raw PSD template is too large") }
            guard let bytes = SmartMap.fromHex(hex) else { throw PCIOError.corrupt("Camera Raw PSD template is not valid hex") }
            do { item = try PSDDescriptor(bytes: bytes) } catch { throw PCIOError.corrupt("bad Camera Raw PSD template: \(error)") }
            if !item.classID.is("filterFX") || SmartMap.int(item, "filterID") != filterID
                || SmartMap.getDesc(item, "Fltr").flatMap(descriptorParams) == nil {
                throw PCIOError.unsupported("Camera Raw PSD template is not a supported Camera Raw filter")
            }
        } else {
            item = PSDDescriptor(classID: "filterFX")
                .with("Nm  ", .text(.nulTerminated("Camera Raw Filter")))
                .with("hasoptions", .boolean(true))
                .with("FrgC", SmartMap.rgbc(0))
                .with("BckC", SmartMap.rgbc(255))
                .with("Fltr", .descriptor(PSDDescriptor(classID: DID(className))
                        .with("CrVe", .text(.nulTerminated("18.4")))
                        .with("PrVN", .integer(6))
                        .with("PrVe", .integer(251_920_384))))
                .with("filterID", .integer(filterID))
        }
        let typed: CameraRawSettings
        do { typed = try CameraRawSettings(json: params) } catch { throw PCIOError.unsupported("bad Camera Raw parameters: \(SmartMap.message(error))") }
        if let e = typed.validate() { throw PCIOError.unsupported(e) }
        let normalized = typed.json
        for (key, value) in (normalized.objectValue ?? [:]).sorted(by: { $0.key < $1.key }) where !supportedParam(key) && defaults[key] != value {
            throw PCIOError.unsupported("Camera Raw setting `\(key)` has no verified PSD mapping")
        }
        if let e = validateSplits(normalized) { throw PCIOError.unsupported(e) }
        guard var d = SmartMap.getDesc(item, "Fltr") else { throw PCIOError.corrupt("Camera Raw PSD template has no filter settings") }
        guard let original = descriptorParams(d) else { throw PCIOError.unsupported("unsupported Camera Raw processing version or settings") }
        for (param, key) in scalars {
            guard let value = getParam(normalized, param) else { throw PCIOError.unsupported("missing Camera Raw parameter") }
            if getParam(original, param) != value {
                try writeNumber(&d, key, value)
                if key == "Temp" || key == "Tint" { SmartMap.set(&d, "WBal", .enumerated(type: "WBal", value: "Cst ")) }
            }
        }
        for (param, key) in curves {
            guard let value = normalized[param] else { throw PCIOError.unsupported("missing Camera Raw curve") }
            if original[param] != value {
                guard let points = value.arrayValue else { throw PCIOError.unsupported("Camera Raw curve must be an array") }
                var levels: [[Float]] = []
                for point in points {
                    guard let coordinates = point.arrayValue, coordinates.count == 2 else {
                        throw PCIOError.unsupported("Camera Raw curve point must contain two coordinates")
                    }
                    var level: [Float] = []
                    for c in coordinates {
                        guard let n = c.doubleValue, n.isFinite, (0.0 ... 255.0).contains(n) else {
                            throw PCIOError.unsupported("Camera Raw curve coordinates must be levels 0–255")
                        }
                        level.append(Float(n.rounded()))
                    }
                    levels.append(level)
                }
                if levels.isEmpty { levels = [[0, 0], [255, 255]] }
                if let e = CameraRawSettings.validateCurve(levels) { throw PCIOError.unsupported("Camera Raw `\(param)`: \(e)") }
                SmartMap.set(&d, key, .list(levels.flatMap { $0 }.map { .integer(Int32($0)) }))
            }
        }
        for (param, keys) in arrays {
            for (index, key) in keys.enumerated() {
                guard let value = normalized[param]?[index] else { throw PCIOError.unsupported("missing Camera Raw array parameter") }
                if original[param]?[index] != value { try writeNumber(&d, key, value) }
            }
        }
        SmartMap.set(&item, "Fltr", .descriptor(d))
        return item
    }
}

/// photocraft-algo's `CameraRaw` settings (Adobe Camera Raw slider units) as serde reads and writes
/// them: camelCase keys, every field defaulted when missing, unknown keys ignored, `f32` numbers
/// (written back as the `f64` of the `f32`, non-finite as `null`), fixed-size arrays.
struct CameraRawSettings: Equatable, Codable {
    /// Most points a Camera Raw point curve accepts from commands and the control channel.
    static let maxCurvePoints = 16

    /// One colour grading wheel (`#[serde(default)]`).
    struct Wheel: Equatable {
        /// Degrees 0..360.
        var hue: Float = 0
        /// 0..=100.
        var sat: Float = 0
        /// −100..=100.
        var lum: Float = 0
    }

    var temperature: Float = 0, tint: Float = 0, exposure: Float = 0, contrast: Float = 0, highlights: Float = 0
    var shadows: Float = 0, whites: Float = 0, blacks: Float = 0, texture: Float = 0, clarity: Float = 0
    var dehaze: Float = 0, vibrance: Float = 0, saturation: Float = 0
    var curveHighlights: Float = 0, curveLights: Float = 0, curveDarks: Float = 0, curveShadows: Float = 0
    /// Region splits (percent).
    var curveSplits: [Float] = [25, 50, 75]
    /// Point curves as `[input, output]` in 0..=255 (empty = linear).
    var pointCurve: [[Float]] = [], pointCurveRed: [[Float]] = [], pointCurveGreen: [[Float]] = [], pointCurveBlue: [[Float]] = []
    // Color mixer: red, orange, yellow, green, aqua, blue, purple, magenta.
    var hslHue = [Float](repeating: 0, count: 8), hslSat = [Float](repeating: 0, count: 8), hslLum = [Float](repeating: 0, count: 8)
    var gradeShadows = Wheel(), gradeMidtones = Wheel(), gradeHighlights = Wheel(), gradeGlobal = Wheel()
    var gradeBlending: Float = 50, gradeBalance: Float = 0
    var sharpenAmount: Float = 0, sharpenRadius: Float = 1, sharpenDetail: Float = 25, sharpenMasking: Float = 0
    var noiseLuminance: Float = 0, noiseLuminanceDetail: Float = 50, noiseColor: Float = 0, noiseColorDetail: Float = 50
    var grainAmount: Float = 0, grainSize: Float = 25, grainRoughness: Float = 50
    var vignetteAmount: Float = 0, vignetteMidpoint: Float = 50, vignetteRoundness: Float = 0, vignetteFeather: Float = 50
    var vignetteHighlights: Float = 0
    /// `highlightPriority | colorPriority | paintOverlay`.
    var vignetteStyle = "highlightPriority"
    var seed: UInt32 = 0
    /// Pixel-size multiplier for previews on downsampled proxies.
    var pixelScale: Float = 1
    /// The document's transfer curve: 0 for sRGB's, else the gamma of a power-law space.
    var encodingGamma: Float = 0

    init() {}

    static var floats: [(String, WritableKeyPath<CameraRawSettings, Float>)] { [
        ("temperature", \.temperature), ("tint", \.tint), ("exposure", \.exposure), ("contrast", \.contrast),
        ("highlights", \.highlights), ("shadows", \.shadows), ("whites", \.whites), ("blacks", \.blacks), ("texture", \.texture),
        ("clarity", \.clarity), ("dehaze", \.dehaze), ("vibrance", \.vibrance), ("saturation", \.saturation),
        ("curveHighlights", \.curveHighlights), ("curveLights", \.curveLights), ("curveDarks", \.curveDarks),
        ("curveShadows", \.curveShadows), ("gradeBlending", \.gradeBlending), ("gradeBalance", \.gradeBalance),
        ("sharpenAmount", \.sharpenAmount), ("sharpenRadius", \.sharpenRadius), ("sharpenDetail", \.sharpenDetail),
        ("sharpenMasking", \.sharpenMasking), ("noiseLuminance", \.noiseLuminance), ("noiseLuminanceDetail", \.noiseLuminanceDetail),
        ("noiseColor", \.noiseColor), ("noiseColorDetail", \.noiseColorDetail), ("grainAmount", \.grainAmount),
        ("grainSize", \.grainSize), ("grainRoughness", \.grainRoughness), ("vignetteAmount", \.vignetteAmount),
        ("vignetteMidpoint", \.vignetteMidpoint), ("vignetteRoundness", \.vignetteRoundness), ("vignetteFeather", \.vignetteFeather),
        ("vignetteHighlights", \.vignetteHighlights), ("pixelScale", \.pixelScale), ("encodingGamma", \.encodingGamma),
    ] }
    static var fixedArrays: [(String, WritableKeyPath<CameraRawSettings, [Float]>, Int)] { [
        ("curveSplits", \.curveSplits, 3), ("hslHue", \.hslHue, 8), ("hslSat", \.hslSat, 8), ("hslLum", \.hslLum, 8),
    ] }
    static var pointCurves: [(String, WritableKeyPath<CameraRawSettings, [[Float]]>)] { [
        ("pointCurve", \.pointCurve), ("pointCurveRed", \.pointCurveRed), ("pointCurveGreen", \.pointCurveGreen),
        ("pointCurveBlue", \.pointCurveBlue),
    ] }
    static var wheels: [(String, WritableKeyPath<CameraRawSettings, Wheel>)] { [
        ("gradeShadows", \.gradeShadows), ("gradeMidtones", \.gradeMidtones), ("gradeHighlights", \.gradeHighlights),
        ("gradeGlobal", \.gradeGlobal),
    ] }

    /// serde's description of a JSON value in a type error.
    static func describe(_ v: JSONValue) -> String {
        switch v {
        case .null: "null"
        case let .bool(b): "boolean `\(b)`"
        case let .number(n): "number `\(n)`"
        case let .string(s): "string \"\(s)\""
        case .array: "sequence"
        case .object: "map"
        }
    }

    /// serde's `f32` from a JSON number (`as f32`: out-of-range values become infinite).
    static func float(_ v: JSONValue) throws -> Float {
        guard case let .number(n) = v else { throw PCIOError.unsupported("invalid type: \(describe(v)), expected f32") }
        return Float(n)
    }

    static func floatArray(_ v: JSONValue, count: Int?) throws -> [Float] {
        guard case let .array(a) = v else { throw PCIOError.unsupported("invalid type: \(describe(v)), expected an array") }
        if let count, a.count != count { throw PCIOError.unsupported("invalid length \(a.count), expected an array of length \(count)") }
        return try a.map(float)
    }

    /// Decodes like `serde_json::from_value::<CameraRaw>`.
    init(json: JSONValue) throws {
        guard case let .object(o) = json else { throw PCIOError.unsupported("invalid type: \(Self.describe(json)), expected struct CameraRaw") }
        for (name, kp) in Self.floats { if let v = o[name] { self[keyPath: kp] = try Self.float(v) } }
        for (name, kp, n) in Self.fixedArrays { if let v = o[name] { self[keyPath: kp] = try Self.floatArray(v, count: n) } }
        for (name, kp) in Self.pointCurves {
            if let v = o[name] {
                guard case let .array(points) = v else { throw PCIOError.unsupported("invalid type: \(Self.describe(v)), expected a sequence") }
                self[keyPath: kp] = try points.map { try Self.floatArray($0, count: 2) }
            }
        }
        for (name, kp) in Self.wheels {
            guard let v = o[name] else { continue }
            var w = Wheel()
            switch v {
            case let .object(f):
                if let x = f["hue"] { w.hue = try Self.float(x) }
                if let x = f["sat"] { w.sat = try Self.float(x) }
                if let x = f["lum"] { w.lum = try Self.float(x) }
            case let .array(a):
                // serde's derived structs also read the sequence form (fields in order).
                if a.count > 3 { throw PCIOError.unsupported("invalid length \(a.count), expected struct Wheel with 3 elements") }
                if a.count > 0 { w.hue = try Self.float(a[0]) }
                if a.count > 1 { w.sat = try Self.float(a[1]) }
                if a.count > 2 { w.lum = try Self.float(a[2]) }
            default:
                throw PCIOError.unsupported("invalid type: \(Self.describe(v)), expected struct Wheel")
            }
            self[keyPath: kp] = w
        }
        if let v = o["vignetteStyle"] {
            guard case let .string(s) = v else { throw PCIOError.unsupported("invalid type: \(Self.describe(v)), expected a string") }
            vignetteStyle = s
        }
        if let v = o["seed"] {
            // JSON numbers here are Doubles: an integral value in u32's range stands for serde's
            // unsigned integer.
            guard case let .number(n) = v, n == n.rounded(), n >= 0, n <= Double(UInt32.max) else {
                throw PCIOError.unsupported("invalid type: \(Self.describe(v)), expected u32")
            }
            seed = UInt32(n)
        }
    }

    /// `serde_json::to_value`: `f32` as the `f64` of the `f32`, non-finite as `null`.
    static func number(_ f: Float) -> JSONValue { f.isFinite ? .number(Double(f)) : .null }

    static func curveJSON(_ points: [[Float]]) -> JSONValue { .array(points.map { .array($0.map(number)) }) }

    var json: JSONValue {
        var o: [String: JSONValue] = [:]
        for (name, kp) in Self.floats { o[name] = Self.number(self[keyPath: kp]) }
        for (name, kp, _) in Self.fixedArrays { o[name] = .array(self[keyPath: kp].map(Self.number)) }
        for (name, kp) in Self.pointCurves { o[name] = Self.curveJSON(self[keyPath: kp]) }
        for (name, kp) in Self.wheels {
            let w = self[keyPath: kp]
            o[name] = ["hue": Self.number(w.hue), "sat": Self.number(w.sat), "lum": Self.number(w.lum)]
        }
        o["vignetteStyle"] = .string(vignetteStyle)
        o["seed"] = .number(Double(seed))
        return .object(o)
    }

    init(from decoder: any Decoder) throws { try self.init(json: try JSONValue(from: decoder)) }

    func encode(to encoder: any Encoder) throws { try json.encode(to: encoder) }

    /// Checks a point curve from untrusted input: empty (linear) or 2..=16 finite points in 0..=255
    /// with inputs increasing by at least one level. nil when it is valid.
    static func validateCurve(_ points: [[Float]]) -> String? {
        if points.count == 1 { return "a nonempty curve needs at least two points" }
        if points.count > maxCurvePoints { return "at most \(maxCurvePoints) curve points" }
        if !points.joined().allSatisfy({ $0.isFinite && (0 ... 255).contains($0) }) { return "curve coordinates must be finite and in 0..=255" }
        for i in points.indices.dropFirst() where points[i].count == 2 && points[i - 1].count == 2 {
            if points[i][0] - points[i - 1][0] < 1 { return "curve inputs must increase by at least one level" }
        }
        return nil
    }

    /// Rejects malformed point curves in new settings.
    func validate() -> String? {
        for (name, kp) in Self.pointCurves {
            if let e = Self.validateCurve(self[keyPath: kp]) { return "\(name): \(e)" }
        }
        return nil
    }
}
