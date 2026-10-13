// Port of photocraft-engine (crates/engine/src/adjust_params.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Full parameter sets for the per-pixel adjustment kinds, shared by the destructive
// `image.adjustments.*` commands, `layer.newAdjustmentLayer.*` and `layer.setAdjustment`.
//
// `fromParams` reads params over a base adjustment (missing keys keep the base's value, so a
// partial update only changes what it names) and `toParams` writes the complete set back, so
// `fromParams(kind, toParams(a), base: nil, mode) == a`. Values out of range are clamped like
// Photoshop's fields; a key of the wrong type is an error.
//
// Units: Levels and Curves in 0–255 levels; percentages for the rest (as in Photoshop's dialogs);
// colours as `"#rrggbb"` or `[r, g, b]` in 0–1. Also the Levels / Curves eyedroppers (Set
// Black / Neutral Gray / White Point), which resolve a colour sample into an ordinary adjustment.

import Foundation
import PCDocument
import PCFoundation
import PCRender

public enum AdjustParams {
    /// Hue/Saturation and Black & White colour-range keys (storage order).
    public static let hueRanges = ["reds", "yellows", "greens", "cyans", "blues", "magentas"]

    /// Black & White default weights (percent) for `hueRanges`.
    public static let bwDefaults: [Float] = [40, 60, 40, 60, 20, 80]

    /// Photo Filter presets `(id, label, colour)`: common photographic filter colours.
    public static let photoFilters: [(id: String, label: String, rgb: [UInt8])] = [
        ("warming85", "Warming Filter (85)", [236, 138, 0]),
        ("warmingLBA", "Warming Filter (LBA)", [250, 150, 0]),
        ("warming81", "Warming Filter (81)", [235, 177, 19]),
        ("cooling80", "Cooling Filter (80)", [0, 109, 255]),
        ("coolingLBB", "Cooling Filter (LBB)", [0, 93, 255]),
        ("cooling82", "Cooling Filter (82)", [0, 181, 255]),
        ("red", "Red", [234, 26, 26]),
        ("orange", "Orange", [243, 132, 23]),
        ("yellow", "Yellow", [249, 227, 28]),
        ("green", "Green", [25, 201, 25]),
        ("cyan", "Cyan", [29, 203, 234]),
        ("blue", "Blue", [29, 53, 234]),
        ("violet", "Violet", [155, 29, 234]),
        ("magenta", "Magenta", [227, 24, 227]),
        ("sepia", "Sepia", [172, 122, 51]),
        ("deepRed", "Deep Red", [255, 0, 0]),
        ("deepBlue", "Deep Blue", [0, 34, 205]),
        ("deepEmerald", "Deep Emerald", [0, 140, 0]),
        ("deepYellow", "Deep Yellow", [255, 213, 0]),
        ("underwater", "Underwater", [0, 194, 177]),
    ]

    /// Most points a curve may have (Photoshop allows 16; the PSD record holds 19).
    public static let maxCurvePoints = 19
    /// Points Photoshop's "Edit points to modify the curve" places on a pencil-drawn curve at most.
    static let maxFittedPoints = 16
    /// Most Smooth passes one `smooth` param applies.
    public static let maxSmoothPasses: Float = 10
    static let curveCoordinatePrecision: Float = 100
    static let curvePointDuplicateDistance: Float = 0.5 / 255
    /// The smallest input range Levels allows (two levels), as the parser enforces.
    static let levelsMinRange: Float = 2.0 / 255.0
    static let eyedropper = "eyedropper"
    /// The Eyedropper's Sample Sizes (photocraft `sample_cmds::SAMPLE_SIZES`).
    static let sampleSizes: [UInt32] = [1, 3, 5, 11, 31, 51, 101]

    /// The neutral Black & White tint (Photoshop's light sepia).
    static let defaultTint = SIMD3<Float>(0.882, 0.827, 0.702)

    /// Per-channel keys of Levels/Curves in each tone space (after the composite).
    public static func channelKeys(_ space: ToneSpace) -> [String] {
        switch space {
        case .rgb: ["red", "green", "blue"]
        case .cmyk: ["cyan", "magenta", "yellow", "black"]
        case .lab: ["lightness", "a", "b"]
        }
    }

    /// The tone space new Levels/Curves get in a document of `mode`.
    public static func defaultSpace(_ mode: ColorMode) -> ToneSpace {
        switch mode {
        case .cmyk: .cmyk
        case .lab: .lab
        default: .rgb
        }
    }

    /// photocraft `commands::adjustment_kind`.
    public static func kind(of a: Adjustment) -> String {
        switch a {
        case .brightnessContrast: "brightnessContrast"
        case .levels: "levels"
        case .curves: "curves"
        case .exposure: "exposure"
        case .vibrance: "vibrance"
        case .hueSaturation: "hueSaturation"
        case .colorBalance: "colorBalance"
        case .blackWhite: "blackWhite"
        case .photoFilter: "photoFilter"
        case .channelMixer: "channelMixer"
        case .posterize: "posterize"
        case .threshold: "threshold"
        case .gradientMap: "gradientMap"
        case .selectiveColor: "selectiveColor"
        case .colorLookup: "colorLookup"
        default: "invert"
        }
    }

    /// The neutral adjustment of `kind` (what "Reset to defaults" restores).
    public static func defaultFor(_ kind: String, mode: ColorMode) throws -> Adjustment {
        try fromParams(kind, .object([:]), base: nil, mode: mode)
    }

    /// Params with the private keys (`layer`, `coalesce`, `channel`, `targetChannel`, `__…`) removed.
    public static func userKeys(_ p: JSONValue) -> [String: JSONValue] {
        p.members.filter { !["layer", "coalesce", "channel", "targetChannel"].contains($0.key) && !$0.key.hasPrefix("__") }
    }

    // MARK: from_params

    /// Reads the adjustment of `kind` from `p` over `base` (or the kind's defaults when `base` is
    /// nil or of another kind). `mode` picks the Levels/Curves channel space when neither the params
    /// nor the base name one.
    public static func fromParams(_ kind: String, _ p: JSONValue, base: Adjustment?, mode: ColorMode) throws -> Adjustment {
        let cmd = "adjustment `\(kind)`"
        if p.objectValue == nil && p != .null { throw EngineError.bad(cmd, "params must be an object") }
        let r = Reader(cmd: cmd, p: p)
        switch kind {
        case "invert":
            return .invert
        case "brightnessContrast":
            var b0 = Adjustment.BrightnessContrast()
            if case .brightnessContrast(let bc)? = base { b0 = bc }
            // `mode` (Photoshop 27: legacy / modern / light) wins over `legacy`; without either the
            // base's mode is kept (a new adjustment is modern, as before).
            let legacy = try r.boolean("legacy", b0.legacy)
            var mode: Adjustment.BrightnessContrast.Mode = r.get("legacy") != nil ? (legacy ? .legacy : (b0.mode == .legacy ? .modern : b0.mode)) : b0.mode
            if let m = r.get("mode") {
                guard case .string(let name) = m, let parsed = Adjustment.BrightnessContrast.Mode(rawValue: name) else {
                    throw EngineError.bad(cmd, "`mode` must be \"legacy\", \"modern\" or \"light\"")
                }
                mode = parsed
            }
            // Photoshop 27's ranges: Light's Contrast −100…100, Modern's −50…100 (M3 descriptor).
            let (lo, hi): (Float, Float) = mode == .modern ? (-50, 100) : (-100, 100)
            let brightness = try r.num("brightness", b0.brightness, -150, 150)
            let contrast = try r.num("contrast", b0.contrast, lo, hi)
            guard mode == .light else { return .brightnessContrast(.init(brightness: brightness, contrast: contrast, mode: mode)) }
            return .brightnessContrast(.init(brightness: brightness, contrast: contrast, mode: .light,
                                             exposure: try r.num("exposure", b0.exposure, -5, 5), whites: try r.num("whites", b0.whites, -100, 100),
                                             blacks: try r.num("blacks", b0.blacks, -100, 100), highlights: try r.num("highlights", b0.highlights, -100, 100),
                                             shadows: try r.num("shadows", b0.shadows, -100, 100)))
        case "threshold":
            var l0: Float = 128
            if case .threshold(let level)? = base { l0 = level * 255 }
            return .threshold(level: try r.num("level", l0, 1, 255).rounded() / 255)
        case "posterize":
            var l0: Float = 4
            if case .posterize(let levels)? = base { l0 = Float(levels) }
            return .posterize(levels: UInt32(try r.num("levels", l0, 2, 255).rounded()))
        case "exposure":
            var e: Float = 0, o: Float = 0, g: Float = 1
            if case .exposure(let x)? = base { (e, o, g) = (x.exposure, x.offset, x.gamma) }
            let exposure = try r.num("exposure", e, -20, 20)
            let offset = try r.num("offset", o, -0.5, 0.5)
            let gamma = try r.num("gamma", g, 0.01, 9.99)
            return .exposure(.init(exposure: exposure, offset: offset, gamma: gamma))
        case "vibrance":
            var v: Float = 0, s: Float = 0
            if case .vibrance(let x)? = base { (v, s) = (x.vibrance, x.saturation) }
            let vibrance = try r.num("vibrance", v, -100, 100)
            let saturation = try r.num("saturation", s, -100, 100)
            return .vibrance(.init(vibrance: vibrance, saturation: saturation))
        case "hueSaturation":
            return try hueSaturation(r, base)
        case "levels":
            return try levels(r, base, mode)
        case "curves":
            return try curves(r, base, mode)
        case "colorBalance":
            var tones: [SIMD3<Float>] = [.zero, .zero, .zero]
            var preserve = true
            if case .colorBalance(let cb)? = base { (tones, preserve) = ([cb.shadows, cb.midtones, cb.highlights], cb.preserveLuminosity) }
            for (i, key) in ["shadows", "midtones", "highlights"].enumerated() {
                if let v = try r.numbers(key, 3) {
                    tones[i] = SIMD3(clamp(v[0], -100, 100), clamp(v[1], -100, 100), clamp(v[2], -100, 100))
                }
            }
            let pl = try r.boolean("preserveLuminosity", preserve)
            return .colorBalance(.init(shadows: tones[0], midtones: tones[1], highlights: tones[2], preserveLuminosity: pl))
        case "blackWhite":
            var weights = bwDefaults
            var tint0: SIMD3<Float>?
            if case .blackWhite(let bw)? = base {
                weights = bw.weights
                tint0 = bw.tint
            }
            // A stored document's weights are untrusted: keep exactly six.
            weights = (0..<6).map { $0 < weights.count ? weights[$0] : bwDefaults[$0] }
            for (i, key) in hueRanges.enumerated() {
                weights[i] = try r.num(key, weights[i], -200, 300)
            }
            // Photoshop's default tint colour is a light sepia.
            let color = try r.color("tintColor", tint0 ?? defaultTint)
            let tint = try r.boolean("tint", tint0 != nil) ? color : nil
            return .blackWhite(.init(weights: weights, tint: tint))
        case "photoFilter":
            var c0 = SIMD3<Float>(236.0 / 255.0, 138.0 / 255.0, 0)
            var d0: Float = 0.25
            var p0 = true
            if case .photoFilter(let pf)? = base { (c0, d0, p0) = (pf.color, pf.density, pf.preserveLuminosity) }
            var preset: SIMD3<Float>?
            switch p["filter"] {
            case nil, .null?:
                preset = nil
            case .string(let id)?:
                guard let f = photoFilters.first(where: { $0.id == id }) else { throw EngineError.bad(cmd, "unknown filter `\(id)`") }
                preset = SIMD3(Float(f.rgb[0]) / 255, Float(f.rgb[1]) / 255, Float(f.rgb[2]) / 255)
            case _?:
                throw EngineError.bad(cmd, "`filter` must be a preset id")
            }
            let color = try r.color("color", preset ?? c0)
            let density = try r.num("density", d0 * 100, 0, 100) / 100
            let pl = try r.boolean("preserveLuminosity", p0)
            return .photoFilter(.init(color: color, density: density, preserveLuminosity: pl))
        case "channelMixer":
            var matrix: [SIMD4<Float>] = [SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0)]
            var mono0 = false
            if case .channelMixer(let cm)? = base {
                matrix = (0..<3).map { $0 < cm.matrix.count ? cm.matrix[$0] : matrix[$0] }
                mono0 = cm.monochrome
            }
            let monochrome = try r.boolean("monochrome", mono0)
            if monochrome && !mono0 && p["gray"] == nil {
                // Turning Monochrome on starts from Photoshop's grey mix.
                matrix[0] = SIMD4(0.4, 0.4, 0.2, 0)
            }
            for (i, key) in ["red", "green", "blue"].enumerated() {
                if let v = try r.numbers(key, 4) { matrix[i] = mixerRow(v) }
            }
            if let v = try r.numbers("gray", 4) { matrix[0] = mixerRow(v) }
            return .channelMixer(.init(matrix: matrix, monochrome: monochrome))
        case "gradientMap":
            var stops0 = [GradientMapStop(0, .zero), GradientMapStop(1, .one)]
            var rev0 = false, dither0 = false
            if case .gradientMap(let gm)? = base { (stops0, rev0, dither0) = (gm.stops, gm.reverse, gm.dither) }
            let stops: [GradientMapStop]
            switch p["stops"] {
            case nil, .null?: stops = stops0
            case let v?: stops = try gradientStops(cmd, v)
            }
            let reverse = try r.boolean("reverse", rev0)
            let dither = try r.boolean("dither", dither0)
            return .gradientMap(.init(stops: stops, reverse: reverse, dither: dither))
        case "selectiveColor":
            var b: Adjustment?
            if case .selectiveColor? = base { b = base }
            return try AdjustCommands.selectiveFromParams(p, base: b)
        case "colorLookup":
            var b: Adjustment?
            if case .colorLookup? = base { b = base }
            return try AdjustCommands.lookupFromParams(p, base: b)
        default:
            throw EngineError.bad("adjustment", "unknown adjustment kind `\(kind)`")
        }
    }

    // MARK: to_params

    /// The complete parameter set of `adj` (the inverse of `fromParams`).
    public static func toParams(_ adj: Adjustment) -> JSONValue {
        switch adj {
        case .invert, .unsupported:
            return .object([:])
        case .brightnessContrast(let bc):
            guard bc.mode == .light else { return ["brightness": num(bc.brightness), "contrast": num(bc.contrast), "legacy": .bool(bc.legacy)] }
            return ["brightness": num(bc.brightness), "contrast": num(bc.contrast), "legacy": .bool(false), "mode": "light",
                    "exposure": num(bc.exposure), "whites": num(bc.whites), "blacks": num(bc.blacks), "highlights": num(bc.highlights),
                    "shadows": num(bc.shadows)]
        case .threshold(let level):
            return ["level": num((level * 255).rounded())]
        case .posterize(let levels):
            return ["levels": .int(Int(levels))]
        case .exposure(let x):
            return ["exposure": num(x.exposure), "offset": num(x.offset), "gamma": num(x.gamma)]
        case .vibrance(let x):
            return ["vibrance": num(x.vibrance), "saturation": num(x.saturation)]
        case .hueSaturation(let hs):
            var v: [String: JSONValue] = ["hue": num(hs.hue), "saturation": num(hs.saturation), "lightness": num(hs.lightness), "colorize": .bool(hs.colorize)]
            for (key, r) in zip(hueRanges, hs.ranges) {
                v[key] = ["hue": num(r.hue), "saturation": num(r.saturation), "lightness": num(r.lightness),
                          "range": .array([num(r.bounds.x), num(r.bounds.y), num(r.bounds.z), num(r.bounds.w)])]
            }
            return .object(v)
        case .levels(let lv):
            var v = levelsObj(lv.master)
            let pc = levelsChannels(lv)
            for (key, c) in zip(channelKeys(lv.space), [pc[0], pc[1], pc[2], lv.black]) {
                v[key] = .object(levelsObj(c))
            }
            if lv.space == .lab {
                // No composite in Lab: the top-level keys are the lightness channel.
                v = merge(levelsObj(pc[0]), v)
            }
            return .object(v)
        case .curves(let cv):
            let pencil = cv.pencil
            func arr(_ c: [CurvePoint]) -> JSONValue { pencil ? mapArr(c) : curveArr(c) }
            var v: [String: JSONValue] = ["points": arr(cv.master)]
            let ink = cv.black.count >= 2 ? cv.black : identityCurve()
            let pc = curveChannels(cv)
            let chans = pc + [ink]
            for (key, c) in zip(channelKeys(cv.space), chans) {
                v[key] = arr(c)
            }
            if cv.space == .lab { v["points"] = arr(pc[0]) }
            if pencil { v["pencil"] = .bool(true) }
            return .object(v)
        case .colorBalance(let cb):
            return ["shadows": vec3(cb.shadows), "midtones": vec3(cb.midtones), "highlights": vec3(cb.highlights),
                    "preserveLuminosity": .bool(cb.preserveLuminosity)]
        case .blackWhite(let bw):
            var v: [String: JSONValue] = ["tint": .bool(bw.tint != nil), "tintColor": .string(hex(bw.tint ?? defaultTint))]
            for (key, w) in zip(hueRanges, bw.weights) { v[key] = num(w) }
            return .object(v)
        case .photoFilter(let pf):
            return ["color": .string(hex(pf.color)), "density": num((pf.density * 1000).rounded() / 10), "preserveLuminosity": .bool(pf.preserveLuminosity)]
        case .channelMixer(let cm):
            func row(_ i: Int) -> JSONValue {
                let r = i < cm.matrix.count ? cm.matrix[i] : SIMD4<Float>.zero
                return .array([r.x, r.y, r.z, r.w].map { num(($0 * 1000).rounded() / 10) })
            }
            var v: [String: JSONValue] = ["red": row(0), "green": row(1), "blue": row(2), "monochrome": .bool(cm.monochrome)]
            if cm.monochrome { v["gray"] = row(0) }
            return .object(v)
        case .gradientMap(let gm):
            return ["stops": .array(gm.stops.map { .array([num($0.location), .string(hex($0.rgb))]) }), "reverse": .bool(gm.reverse), "dither": .bool(gm.dither)]
        case .selectiveColor(let sc):
            var v: [String: JSONValue] = ["method": .string(sc.relative ? "relative" : "absolute")]
            for (i, key) in AdjustCommands.ranges.enumerated() {
                let a = i < sc.adjustments.count ? sc.adjustments[i] : SIMD4<Float>.zero
                v[key] = .array([num(a.x), num(a.y), num(a.z), num(a.w)])
            }
            return .object(v)
        case .colorLookup(let cl):
            return ["interpolation": .string(cl.tetrahedral ? "tetrahedral" : "trilinear"), "dither": .bool(cl.dither)]
        }
    }

    // MARK: Helpers

    static func num(_ f: Float) -> JSONValue { .number(Double(f)) }
    static func vec3(_ v: SIMD3<Float>) -> JSONValue { .array([num(v.x), num(v.y), num(v.z)]) }

    /// Rust `f32::clamp`.
    @inline(__always) static func clamp(_ x: Float, _ lo: Float, _ hi: Float) -> Float { Swift.min(Swift.max(x, lo), hi) }

    /// Rust `f32::rem_euclid`.
    static func remEuclid(_ x: Float, _ m: Float) -> Float {
        let r = x.truncatingRemainder(dividingBy: m)
        return r < 0 ? r + abs(m) : r
    }

    /// Typed, clamped access to optional params.
    struct Reader {
        let cmd: String
        let p: JSONValue

        func get(_ key: String) -> JSONValue? {
            guard let v = p[key], v != .null else { return nil }
            return v
        }

        func num(_ key: String, _ def: Float, _ lo: Float, _ hi: Float) throws -> Float {
            guard let v = get(key) else { return AdjustParams.clamp(def, lo, hi) }
            return try AdjustParams.numIn(cmd, key, v, lo, hi)
        }

        func boolean(_ key: String, _ def: Bool) throws -> Bool {
            guard let v = get(key) else { return def }
            guard case .bool(let b) = v else { throw EngineError.bad(cmd, "`\(key)` must be true or false") }
            return b
        }

        /// An array of exactly `n` numbers.
        func numbers(_ key: String, _ n: Int) throws -> [Float]? {
            guard let v = get(key) else { return nil }
            guard let a = v.arrayValue, a.count == n else { throw EngineError.bad(cmd, "`\(key)` must be an array of \(n) numbers") }
            return try a.map { try AdjustParams.numIn(cmd, key, $0, -1e6, 1e6) }
        }

        func color(_ key: String, _ def: SIMD3<Float>) throws -> SIMD3<Float> {
            guard let v = get(key) else { return def }
            return try AdjustParams.colorOf(cmd, key, v)
        }

        /// A channel object (`{"inBlack": …}`) or nil.
        func object(_ key: String) throws -> Reader? {
            guard let v = get(key) else { return nil }
            guard v.objectValue != nil else { throw EngineError.bad(cmd, "`\(key)` must be an object") }
            return Reader(cmd: cmd, p: v)
        }
    }

    static func numIn(_ cmd: String, _ key: String, _ v: JSONValue, _ lo: Float, _ hi: Float) throws -> Float {
        guard let x = v.doubleValue, x.isFinite else { throw EngineError.bad(cmd, "`\(key)` must be a number") }
        return clamp(Float(x), lo, hi)
    }

    /// One hex byte the way Rust's `u8::from_str_radix(_, 16)` reads two characters.
    static func hexByte(_ b: ArraySlice<UInt8>) -> UInt8? {
        var digits = Array(b)
        if digits.first == UInt8(ascii: "+") { digits.removeFirst() }
        guard !digits.isEmpty else { return nil }
        var v: UInt16 = 0
        for c in digits {
            let d: UInt8
            switch c {
            case 0x30...0x39: d = c - 0x30
            case 0x41...0x46: d = c - 0x41 + 10
            case 0x61...0x66: d = c - 0x61 + 10
            default: return nil
            }
            v = v * 16 + UInt16(d)
        }
        return v <= 255 ? UInt8(v) : nil
    }

    static func colorOf(_ cmd: String, _ key: String, _ v: JSONValue) throws -> SIMD3<Float> {
        let err = EngineError.bad(cmd, "`\(key)` must be \"#rrggbb\" or [r, g, b] in 0..1")
        switch v {
        case .string(let s):
            let h = Array(s.utf8.drop { $0 == UInt8(ascii: "#") })
            func b(_ i: Int) -> Float? {
                guard i + 2 <= h.count else { return nil }
                // Rust `str::get` fails on a char boundary inside a multi-byte character.
                if i < h.count, h[i] & 0xC0 == 0x80 { return nil }
                if i + 2 < h.count, h[i + 2] & 0xC0 == 0x80 { return nil }
                return hexByte(h[i..<(i + 2)]).map { Float($0) / 255 }
            }
            guard h.count == 6 || h.count == 8, let r = b(0), let g = b(2), let bb = b(4) else { throw err }
            return SIMD3(r, g, bb)
        case .array(let a) where a.count >= 3:
            func c(_ i: Int) throws -> Float {
                guard let x = a[i].doubleValue, x.isFinite else { throw err }
                return clamp(Float(x), 0, 1)
            }
            return SIMD3(try c(0), try c(1), try c(2))
        default:
            throw err
        }
    }

    public static func hex(_ c: SIMD3<Float>) -> String {
        func b(_ v: Float) -> UInt8 {
            let x = (clamp(v, 0, 1) * 255).rounded()
            return x.isNaN ? 0 : UInt8(x)
        }
        return String(format: "#%02x%02x%02x", b(c.x), b(c.y), b(c.z))
    }

    /// `a`'s members, plus `b`'s keys `a` lacks.
    static func merge(_ a: [String: JSONValue], _ b: [String: JSONValue]) -> [String: JSONValue] {
        var out = a
        for (k, v) in b where out[k] == nil { out[k] = v }
        return out
    }

    static func mixerRow(_ v: [Float]) -> SIMD4<Float> {
        func at(_ i: Int) -> Float { clamp(i < v.count ? v[i] : 0, -200, 200) / 100 }
        return SIMD4(at(0), at(1), at(2), at(3))
    }

    static func hueSaturation(_ r: Reader, _ base: Adjustment?) throws -> Adjustment {
        var h: Float = 0, s: Float = 0, l: Float = 0, c = false
        var ranges = HueRange.defaults
        if case .hueSaturation(let hs)? = base { (h, s, l, c, ranges) = (hs.hue, hs.saturation, hs.lightness, hs.colorize, hs.ranges) }
        let colorize = try r.boolean("colorize", c)
        // Colorize hue is 0..360, a shift is -180..180.
        let hue = colorize ? try r.num("hue", remEuclid(h, 360), 0, 360) : try r.num("hue", h, -180, 180)
        // Turning Colorize on starts at 25% saturation unless one is given, like the dialog's
        // checkbox and Photoshop; an explicit 0 stays 0, which colorizes to grey (#2326).
        let s1 = colorize && !c ? Swift.max(s, 25) : s
        let saturation = try r.num("saturation", s1, colorize ? 0 : -100, 100)
        let lightness = try r.num("lightness", l, -100, 100)
        for (i, key) in hueRanges.enumerated() {
            guard let o = try r.object(key) else { continue }
            guard i < ranges.count else { continue }
            ranges[i].hue = try o.num("hue", ranges[i].hue, -180, 180)
            ranges[i].saturation = try o.num("saturation", ranges[i].saturation, -100, 100)
            ranges[i].lightness = try o.num("lightness", ranges[i].lightness, -100, 100)
            if let b = try o.numbers("range", 4) {
                // Keep the four sliders ordered and within one turn of the first.
                ranges[i].bounds = HueRange.canonicalBounds(SIMD4(b[0], b[1], b[2], b[3]))
            }
        }
        return .hueSaturation(.init(hue: hue, saturation: saturation, lightness: lightness, colorize: colorize, ranges: ranges))
    }

    /// Which tone space the params address: any channel key of a space picks it.
    static func spaceOf(_ r: Reader, _ base: ToneSpace?, _ mode: ColorMode) -> ToneSpace {
        func has(_ keys: [String]) -> Bool { keys.contains { r.get($0) != nil } }
        if has(["cyan", "magenta", "yellow", "black"]) { return .cmyk }
        if has(["a", "b"]) || (has(["lightness"]) && !has(["red", "green", "blue"])) { return .lab }
        if has(["red", "green", "blue"]) { return .rgb }
        return base ?? defaultSpace(mode)
    }

    /// The three channel records of a Levels (a stored document's count is untrusted).
    static func levelsChannels(_ lv: Adjustment.Levels) -> [LevelsChannel] {
        (0..<3).map { $0 < lv.perChannel.count ? lv.perChannel[$0] : LevelsChannel() }
    }

    /// The three channel curves of a Curves (a stored document's count is untrusted).
    static func curveChannels(_ cv: Adjustment.Curves) -> [[CurvePoint]] {
        (0..<3).map { $0 < cv.perChannel.count ? cv.perChannel[$0] : [] }
    }

    static func levels(_ r: Reader, _ base: Adjustment?, _ mode: ColorMode) throws -> Adjustment {
        var master = LevelsChannel()
        var chans = [LevelsChannel](repeating: LevelsChannel(), count: 4)
        var baseSpace: ToneSpace?
        if case .levels(let lv)? = base {
            master = lv.master
            chans = levelsChannels(lv) + [lv.black]
            baseSpace = lv.space
        }
        let space = spaceOf(r, baseSpace, mode)
        if let b = baseSpace, b != space { chans = [LevelsChannel](repeating: LevelsChannel(), count: 4) }
        func read(_ o: Reader, _ c: LevelsChannel) throws -> LevelsChannel {
            let inBlack = try o.num("inBlack", c.inBlack * 255, 0, 253)
            let inWhite = Swift.max(try o.num("inWhite", c.inWhite * 255, 2, 255), inBlack + 2)
            let gamma = try o.num("gamma", c.gamma, 0.01, 9.99)
            let outBlack = try o.num("outBlack", c.outBlack * 255, 0, 255) / 255
            let outWhite = try o.num("outWhite", c.outWhite * 255, 0, 255) / 255
            return LevelsChannel(inBlack: inBlack / 255, inWhite: inWhite / 255, gamma: gamma, outBlack: outBlack, outWhite: outWhite)
        }
        if space == .lab {
            // Top-level keys (and "gray") address lightness: Lab has no composite.
            chans[0] = try read(r, chans[0])
        } else {
            master = try read(r, master)
            if let o = try r.object("gray") { master = try read(o, master) }
        }
        for (i, key) in channelKeys(space).enumerated() {
            if let o = try r.object(key), i < chans.count { chans[i] = try read(o, chans[i]) }
        }
        return .levels(.init(master: master, perChannel: [chans[0], chans[1], chans[2]], space: space,
                             black: space == .cmyk ? chans[3] : LevelsChannel()))
    }

    static func identityCurve() -> [CurvePoint] { [CurvePoint(input: 0, output: 0), CurvePoint(input: 1, output: 1)] }

    /// Hundredths of a 0..255 level.
    static func q100(_ v: Float) -> Float { (v * 255 * curveCoordinatePrecision).rounded() / curveCoordinatePrecision }

    static func curveArr(_ c: [CurvePoint]) -> JSONValue {
        let c = c.count >= 2 ? c : identityCurve()
        return .array(c.map { .array([num(q100($0.input)), num(q100($0.output))]) })
    }

    /// A pencil-mode curve as params: its `curveMapLength` outputs in 0..255.
    static func mapArr(_ c: [CurvePoint]) -> JSONValue {
        .array(curveMapOutputs(c).map { num(q100($0)) })
    }

    /// Sorts by input, keeping equal inputs in order (Rust's stable `sort_by`).
    static func sortedByInput(_ pts: [CurvePoint]) -> [CurvePoint] {
        pts.enumerated().sorted { a, b in
            if a.element.input != b.element.input { return a.element.input < b.element.input }
            return a.offset < b.offset
        }.map(\.element)
    }

    /// `lut` (evenly spaced over 0...1) at `x`, linearly interpolated.
    static func lutAt(_ lut: [Float], _ x: Float) -> Float {
        guard !lut.isEmpty else { return x }
        let last = lut.count - 1
        let f = clamp(x, 0, 1) * Float(last)
        let fl = f.rounded(.down)
        let i = Swift.min(fl.isFinite && fl > 0 ? Int(fl) : 0, last)
        let a = lut[i], b = lut[Swift.min(i + 1, last)]
        return a + (b - a) * (f - Float(i))
    }

    /// A point curve drawn into a pencil-mode map (Photoshop switching to "Draw to modify the curve").
    public static func pointsToMap(_ points: [CurvePoint]) -> [CurvePoint] {
        let lut = AdjustMath.curveLUT(points)
        let last = Float(curveMapLength - 1)
        return curveMap((0..<curveMapLength).map { lutAt(lut, Float($0) / last) })
    }

    /// A pencil-mode map turned back into a point curve (Photoshop's "Edit points to modify the
    /// curve"): the endpoints, then the worst-fitting input until the spline is within one level of
    /// the map or `maxFittedPoints` are placed.
    public static func mapToPoints(_ map: [CurvePoint]) -> [CurvePoint] {
        let target = curveMapOutputs(map)
        let last = curveMapLength - 1
        func at(_ k: Int) -> CurvePoint { CurvePoint(input: Float(k) / Float(last), output: k < target.count ? target[k] : 0) }
        var pts = [at(0), at(last)]
        while pts.count < maxFittedPoints {
            let lut = AdjustMath.curveLUT(pts)
            // Rust `max_by`: the last of equal maxima.
            var worst: (Int, Float)?
            for k in 0..<curveMapLength {
                let e = abs(lutAt(lut, Float(k) / Float(last)) - (k < target.count ? target[k] : 0))
                if let w = worst { if !(e < w.1) { worst = (k, e) } } else { worst = (k, e) }
            }
            guard let (k, e) = worst, e > 1.0 / 255.0 else { break }
            let p = at(k)
            if pts.contains(where: { abs($0.input - p.input) < curvePointDuplicateDistance }) { break }
            pts.append(p)
            pts = sortedByInput(pts)
        }
        return pts
    }

    /// One pass of Curves' Smooth button over pencil-mode outputs (any scale): each value becomes
    /// the mean of a symmetric window of up to three neighbours a side, so straight runs and the two
    /// endpoints stay put while jagged strokes even out.
    public static func smoothCurveMap(_ outputs: inout [Float]) {
        let radius = 3
        let src = outputs
        let n = src.count
        for k in 0..<n {
            let r = Swift.min(radius, k, Swift.max(n - (k + 1), 0))
            if r == 0 { continue }
            let window = src[(k - r)...(k + r)]
            outputs[k] = window.reduce(0, +) / Float(Swift.max(window.count, 1))
        }
    }

    /// Whether a pencil-mode curve maps every level to itself.
    static func isIdentityMap(_ c: [CurvePoint]) -> Bool {
        let last = Float(curveMapLength - 1)
        return curveMapOutputs(c).enumerated().allSatisfy { abs($0.element - Float($0.offset) / last) < 0.5 / 255 }
    }

    /// `[[in, out], …]` in 0..255: sorted by input, duplicates collapsed, 2...19 points.
    public static func parseCurve(_ cmd: String, _ key: String, _ v: JSONValue) throws -> [CurvePoint] {
        let err = EngineError.bad(cmd, "`\(key)` must be an array of 2..=\(maxCurvePoints) [input, output] pairs in 0..255")
        guard let a = v.arrayValue else { throw err }
        if a.count < 2 || a.count > 64 { throw err }
        var pts: [CurvePoint] = []
        pts.reserveCapacity(a.count)
        for q in a {
            guard let q = q.arrayValue, q.count == 2 else { throw err }
            guard let x = q[0].doubleValue, x.isFinite, let y = q[1].doubleValue, y.isFinite else { throw err }
            pts.append(CurvePoint(input: clamp(Float(x), 0, 255) / 255, output: clamp(Float(y), 0, 255) / 255))
        }
        pts = sortedByInput(pts)
        var kept: [CurvePoint] = []
        for p in pts {
            if let l = kept.last, abs(p.input - l.input) < curvePointDuplicateDistance { continue }
            kept.append(p)
        }
        if kept.count < 2 || kept.count > maxCurvePoints { throw err }
        return kept
    }

    /// A pencil-mode map param: exactly `curveMapLength` outputs in 0..255.
    static func parseMap(_ cmd: String, _ key: String, _ v: JSONValue) throws -> [CurvePoint] {
        let err = EngineError.bad(cmd, "`\(key)` must be \(curveMapLength) output levels in 0..255 (a pencil-drawn map) or [input, output] pairs")
        guard let a = v.arrayValue, a.count == curveMapLength else { throw err }
        var outs: [Float] = []
        outs.reserveCapacity(a.count)
        for x in a {
            guard let d = x.doubleValue, d.isFinite else { throw err }
            outs.append(clamp(Float(d), 0, 255) / 255)
        }
        return curveMap(outs)
    }

    /// A Curves channel param in the adjustment's mode: `[[in, out], …]` points (drawn into a map in
    /// pencil mode) or a `curveMapLength`-level map (fitted with points outside pencil mode).
    static func parseCurveIn(_ cmd: String, _ key: String, _ v: JSONValue, _ pencil: Bool) throws -> [CurvePoint] {
        if case .number? = v.arrayValue?.first {
            let map = try parseMap(cmd, key, v)
            return pencil ? map : mapToPoints(map)
        }
        let pts = try parseCurve(cmd, key, v)
        return pencil ? pointsToMap(pts) : pts
    }

    static func curves(_ r: Reader, _ base: Adjustment?, _ mode: ColorMode) throws -> Adjustment {
        var master = identityCurve()
        var chans = [[CurvePoint]](repeating: identityCurve(), count: 4)
        var baseSpace: ToneSpace?
        var basePencil = false
        if case .curves(let cv)? = base {
            master = cv.master
            chans = curveChannels(cv) + [cv.black]
            baseSpace = cv.space
            basePencil = cv.pencil
        }
        let space = spaceOf(r, baseSpace, mode)
        if let b = baseSpace, b != space { chans = [[CurvePoint]](repeating: identityCurve(), count: 4) }
        let pencil = try r.boolean("pencil", basePencil)
        // Every stored curve in the adjustment's mode: maps are drawn from the spline when switching
        // to the pencil, fitted with points when switching back, and filled out to full maps.
        func convert(_ c: [CurvePoint]) -> [CurvePoint] {
            switch (basePencil, pencil) {
            case (false, true): return pointsToMap(c)
            case (true, false): return mapToPoints(c)
            case (true, true) where c.count != curveMapLength: return curveMap(curveMapOutputs(c))
            default: return c
            }
        }
        master = convert(master)
        chans = chans.map(convert)
        if let v = r.get("points") ?? r.get("gray") {
            let c = try parseCurveIn(r.cmd, "points", v, pencil)
            if space == .lab { chans[0] = c } else { master = c }
        }
        for (i, key) in channelKeys(space).enumerated() {
            if let v = r.get(key), i < chans.count { chans[i] = try parseCurveIn(r.cmd, key, v, pencil) }
        }
        let passesF = try r.num("smooth", 0, 0, maxSmoothPasses).rounded()
        let passes = passesF > 0 ? Int(passesF) : 0
        if pencil {
            // Smoothed, then held at the params' precision so `toParams` round-trips exactly.
            func level(_ o: Float) -> Float { (o * 255 * curveCoordinatePrecision).rounded() / curveCoordinatePrecision / 255 }
            func smoothed(_ c: [CurvePoint]) -> [CurvePoint] {
                var outs = curveMapOutputs(c)
                for _ in 0..<passes { smoothCurveMap(&outs) }
                return curveMap(outs.map(level))
            }
            master = smoothed(master)
            chans = chans.map(smoothed)
        }
        let black = chans[3]
        let identity = pencil ? isIdentityMap(black) : isIdentityCurve(black)
        return .curves(.init(master: master, perChannel: [chans[0], chans[1], chans[2]], space: space,
                             black: space == .cmyk && !identity ? black : [], pencil: pencil))
    }

    static func levelsObj(_ c: LevelsChannel) -> [String: JSONValue] {
        func q(_ v: Float) -> Float { (v * 255 * 100).rounded() / 100 }
        return ["inBlack": num(q(c.inBlack)), "gamma": num((c.gamma * 1000).rounded() / 1000), "inWhite": num(q(c.inWhite)),
                "outBlack": num(q(c.outBlack)), "outWhite": num(q(c.outWhite))]
    }

    /// `[[location 0..1, colour], …]` (colour as for `color`), sorted by location.
    static func gradientStops(_ cmd: String, _ v: JSONValue) throws -> [GradientMapStop] {
        let err = EngineError.bad(cmd, "`stops` must be an array of 2..=64 [location 0..1, colour] pairs")
        guard let a = v.arrayValue, (2...64).contains(a.count) else { throw err }
        var out: [(Float, SIMD3<Float>)] = []
        for s in a {
            let t: JSONValue?, c: JSONValue?
            switch s {
            case .array(let p) where p.count == 2: (t, c) = (p[0], p[1])
            case .object(let o): (t, c) = (o["location"], o["color"])
            default: throw err
            }
            guard let tv = t?.doubleValue, tv.isFinite else { throw err }
            guard let cv = c else { throw err }
            let color = try colorOf(cmd, "stops", cv)
            out.append((clamp(Float(tv), 0, 1), color))
        }
        let sorted = out.enumerated().sorted { a, b in a.element.0 != b.element.0 ? a.element.0 < b.element.0 : a.offset < b.offset }
        return sorted.map { GradientMapStop($0.element.0, $0.element.1) }
    }

    // MARK: Eyedroppers

    /// Fixed-target Curves / Levels eyedroppers. The UI keeps the sampled operation provisional;
    /// these helpers only resolve a sample into an ordinary adjustment the existing command applies.
    public enum CurvesEyedropper: Sendable, Equatable {
        case black, neutralGray, white
    }

    /// Verify that serializing and parsing `points` keeps every point and the requested anchor.
    static func curveRoundTripKeepsAnchor(_ points: [CurvePoint], _ input: Float, _ output: Float) -> Bool {
        guard let parsed = try? parseCurve("curves eyedropper", "curve", curveArr(points)) else { return false }
        if parsed.count != points.count { return false }
        func serialized(_ v: Float) -> Float { q100(v) / 255 }
        let (i, o) = (serialized(input), serialized(output))
        return parsed.contains { abs($0.input - i) < 1e-6 && abs($0.output - o) < 1e-6 }
    }

    static func moveCurveEndpoint(_ points: inout [CurvePoint], _ sample: Float, black: Bool) {
        let sample = clamp(sample, 0, 1)
        var candidate = points
        if black {
            for i in candidate.indices { candidate[i].input = sample + candidate[i].input * (1 - sample) }
            if !candidate.isEmpty {
                candidate[0].input = sample
                candidate[0].output = 0
            }
        } else {
            for i in candidate.indices { candidate[i].input *= sample }
            if let l = candidate.indices.last {
                candidate[l].input = sample
                candidate[l].output = 1
            }
        }
        // `curveArr` stores hundredths of a 0..255 level, while `parseCurve` drops points
        // separated by less than half a level. Scaling an endpoint toward the sample can collapse
        // several edited points together even when the target endpoint itself survives. Check that
        // the full curve survives the actual serializer and parser.
        if curveRoundTripKeepsAnchor(candidate, sample, black ? 0 : 1) {
            points = candidate
            return
        }
        // If scaling collapses any points, keep the user's point positions and edits, and make the
        // two points nearest the selected endpoint a target plateau.
        if black {
            for i in points.indices.reversed().prefix(2) { points[i].output = 0 }
        } else {
            for i in points.indices.prefix(2) { points[i].output = 1 }
        }
    }

    static func anchorCurve(_ points: inout [CurvePoint], _ input0: Float, _ output0: Float) {
        let input = clamp(input0, 0, 1), output = clamp(output0, 0, 1)
        var candidate = points
        if let i = candidate.firstIndex(where: { abs($0.input - input) < curvePointDuplicateDistance }) {
            candidate[i].input = input
            candidate[i].output = output
        } else if candidate.count < maxCurvePoints {
            candidate.append(CurvePoint(input: input, output: output))
        } else {
            // Rust `min_by`: the first of equal minima, among interior points.
            var best: (Int, Float)?
            for i in candidate.indices where i > 0 && i + 1 < candidate.count {
                let d = abs(candidate[i].input - input)
                if let b = best { if d < b.1 { best = (i, d) } } else { best = (i, d) }
            }
            if let (i, _) = best { candidate[i] = CurvePoint(input: input, output: output) }
        }
        candidate = sortedByInput(candidate)
        if curveRoundTripKeepsAnchor(candidate, input, output) {
            points = candidate
            return
        }
        // A channel sample can land between two points only half a level apart. Moving one point to
        // the sample would then make the parser collapse the pair, so retain their positions and make
        // the bracketing pair a deterministic neutral plateau instead.
        guard !points.isEmpty else { return }
        let last = points.count - 1
        let split = points.firstIndex { !($0.input < input) } ?? points.count
        var lower = Swift.min(Swift.max(split - 1, 0), last)
        var upper = Swift.min(split, last)
        if lower == upper {
            if upper < last { upper += 1 } else { lower = Swift.max(lower - 1, 0) }
        }
        points[lower].output = output
        points[upper].output = output
    }

    /// Rec. 709 luma in the sampled display-RGB values: the neutral level the gray picker
    /// preserves when it removes a colour cast.
    static func rgbLuma(_ rgb: SIMD3<Float>) -> Float { rgb.x * 0.2126 + rgb.y * 0.7152 + rgb.z * 0.0722 }

    /// The master-curve input whose output is closest to `target`. The master curve is kept intact
    /// by the gray picker, so channel curves target its inverse to preserve final luma. A
    /// non-monotone or flat curve may have no exact inverse; the first nearest LUT entry is a
    /// deterministic best fit.
    static func inverseMasterTarget(_ master: [CurvePoint], _ target: Float) -> Float {
        if isIdentityCurve(master) { return target }
        let lut = AdjustMath.curveLUT(master)
        guard lut.count > 1 else { return target }
        let denominator = lut.count - 1
        var bestInput = target
        var bestError = Float.infinity
        for (i, v) in lut.enumerated() {
            let e = abs(v - target)
            if e < bestError {
                bestError = e
                bestInput = Float(i) / Float(denominator)
            }
        }
        return bestInput
    }

    /// The sample and colour modes both eyedroppers (Levels, Curves) support: RGB, and Grayscale
    /// without the Neutral Gray picker.
    static func checkEyedropper(_ cmd: String, _ picker: CurvesEyedropper, _ sample: SIMD3<Float>, _ mode: ColorMode) throws {
        if !(sample.x.isFinite && sample.y.isFinite && sample.z.isFinite) { throw EngineError.bad(cmd, "sample components must be finite") }
        if mode != .rgb && mode != .grayscale { throw EngineError.bad(cmd, "only RGB and Grayscale documents are supported") }
        if mode == .grayscale && picker == .neutralGray { throw EngineError.bad(cmd, "Neutral Gray is unavailable for Grayscale documents") }
    }

    /// Moves the input black (or white) of `c` to `sample`, so the sample maps to the output black
    /// (white). The other input end moves away if it would leave less than two levels between them.
    static func setLevelsInput(_ c: inout LevelsChannel, _ sample: Float, black: Bool) {
        if black {
            c.inBlack = clamp(sample, 0, 1 - levelsMinRange)
            c.inWhite = Swift.min(Swift.max(c.inWhite, c.inBlack + levelsMinRange), 1)
        } else {
            c.inWhite = clamp(sample, levelsMinRange, 1)
            c.inBlack = Swift.max(Swift.min(c.inBlack, c.inWhite - levelsMinRange), 0)
        }
    }

    /// Sets the midtone gamma of `c` so `sample` maps to `target` (both 0...1). Bisection over the
    /// gamma range on the compositor's own Levels curve (monotone in gamma), so the shadow toe is
    /// accounted for. A sample at or outside the input range, or a target outside the output range,
    /// can't be reached by gamma and leaves `c` unchanged.
    static func setLevelsGamma(_ c: inout LevelsChannel, _ sample: Float, _ target: Float) {
        let u = (sample - c.inBlack) / Swift.max(c.inWhite - c.inBlack, 1e-6)
        let span = c.outWhite - c.outBlack
        let t = (target - c.outBlack) / span
        if !(u > 0 && u < 1) || abs(span) < 1e-6 || !(t > 0 && t < 1) { return }
        let ch = c
        func reached(_ gamma: Float) -> Float {
            var trial = ch
            trial.gamma = gamma
            return (AdjustMath.levelsQ(trial, sample, nil) - ch.outBlack) / span
        }
        var lo = logf(0.01), hi = logf(9.99)
        for _ in 0..<40 {
            let mid = (lo + hi) / 2
            if reached(expf(mid)) < t { lo = mid } else { hi = mid }
        }
        c.gamma = clamp(expf((lo + hi) / 2), 0.01, 9.99)
    }

    /// Photoshop's Levels eyedroppers on the Levels in `base` (params, as for `fromParams`), from a
    /// colour sample of the image the Levels adjust. RGB: Set Black/White Point move each channel's
    /// input black/white to the sample's value in that channel, so the sample maps to the output
    /// black/white; Set Neutral Gray Point sets each channel's midtone gamma so the channel maps to
    /// the sample's luma, removing the cast while keeping its brightness. The composite record is
    /// kept. Grayscale: Black/White move the composite input; there is no gray picker.
    public static func levelsEyedropper(_ base: JSONValue, _ picker: CurvesEyedropper, _ sample0: SIMD3<Float>, mode: ColorMode) throws -> Adjustment {
        let cmd = "levels eyedropper"
        try checkEyedropper(cmd, picker, sample0, mode)
        guard case .levels(var lv) = try fromParams("levels", base, base: nil, mode: mode) else { throw EngineError.bad(cmd, "expected a Levels adjustment") }
        if lv.space != .rgb { throw EngineError.bad(cmd, "only RGB channel Levels are supported") }
        let sample = SIMD3(clamp(sample0.x, 0, 1), clamp(sample0.y, 0, 1), clamp(sample0.z, 0, 1))
        if mode == .grayscale {
            setLevelsInput(&lv.master, (sample.x + sample.y + sample.z) / 3, black: picker == .black)
            return .levels(lv)
        }
        lv.perChannel = levelsChannels(lv)
        switch picker {
        case .black, .white:
            for i in 0..<3 { setLevelsInput(&lv.perChannel[i], sample[i], black: picker == .black) }
        case .neutralGray:
            let target = rgbLuma(sample)
            for i in 0..<3 { setLevelsGamma(&lv.perChannel[i], sample[i], target) }
        }
        return .levels(lv)
    }

    /// The eyedropper of adjustment `kind` ("levels" or "curves").
    public static func adjustmentEyedropper(_ kind: String, _ base: JSONValue, _ picker: CurvesEyedropper, _ sample: SIMD3<Float>, mode: ColorMode) throws -> Adjustment {
        switch kind {
        case "levels": return try levelsEyedropper(base, picker, sample, mode: mode)
        case "curves": return try curvesEyedropper(base, picker, sample, mode: mode)
        default: throw EngineError.bad(eyedropper, "`eyedropper` applies to Levels and Curves only")
        }
    }

    /// Resolves a merged-composite colour sample into the black, luma-preserving neutral-gray or
    /// white target. RGB uses the three channel curves. Grayscale uses the composite curve and has
    /// no gray picker. Other colour models stay unsupported until their native channel semantics
    /// can be sampled.
    public static func curvesEyedropper(_ base0: JSONValue, _ picker: CurvesEyedropper, _ sample0: SIMD3<Float>, mode: ColorMode) throws -> Adjustment {
        let cmd = "curves eyedropper"
        try checkEyedropper(cmd, picker, sample0, mode)
        // The pickers place points: a pencil-drawn curve is first fitted with points, as when
        // Photoshop leaves the pencil for point editing.
        var base = base0
        if var o = base.objectValue {
            o["smooth"] = nil
            if o["pencil"]?.boolValue == true { o["pencil"] = .bool(false) }
            base = .object(o)
        }
        guard case .curves(var cv) = try fromParams("curves", base, base: nil, mode: mode) else { throw EngineError.bad(cmd, "expected a Curves adjustment") }
        let sample = SIMD3(clamp(sample0.x, 0, 1), clamp(sample0.y, 0, 1), clamp(sample0.z, 0, 1))
        if mode == .grayscale {
            moveCurveEndpoint(&cv.master, (sample.x + sample.y + sample.z) / 3, black: picker == .black)
            return .curves(cv)
        }
        cv.perChannel = curveChannels(cv)
        switch picker {
        case .black, .white:
            let black = picker == .black
            for i in 0..<3 { moveCurveEndpoint(&cv.perChannel[i], sample[i], black: black) }
            if black {
                if !cv.master.isEmpty { cv.master[0].output = 0 }
            } else if let l = cv.master.indices.last {
                cv.master[l].output = 1
            }
        case .neutralGray:
            // Sampled luma instead of a fixed mid-gray so removing a cast keeps the sample's
            // brightness. The per-channel curves precede the composite curve, so invert the existing
            // master curve while preserving it.
            let target = inverseMasterTarget(cv.master, rgbLuma(sample))
            for i in 0..<3 { anchorCurve(&cv.perChannel[i], sample[i], target) }
        }
        return .curves(cv)
    }

    /// The `eyedropper` param of the Levels and Curves commands (`kind`), so agents and the CLI can
    /// drive the dialog's Set Black/Neutral Gray/White Point pickers:
    /// `{"point":"black"|"gray"|"white","at":[x,y]}` samples the merged composite at document pixel
    /// (x, y) (`"size"`: the Eyedropper's Sample Size, 1 = Point Sample), or `"color":[r,g,b]` (0–1)
    /// gives the sample directly. The rest of `p` is the adjustment the picker edits. nil without
    /// the key.
    public static func eyedropperFromParams(_ s: Session, kind: String, _ p: JSONValue) throws -> Adjustment? {
        guard let e = p["eyedropper"] else { return nil }
        guard let d = s.active else { throw EngineError.noDocument }
        let (picker, sample) = try eyedropperSample(s.services.renderer, d.doc, hide: nil, e)
        return try adjustmentEyedropper(kind, p.removing("eyedropper"), picker, sample, mode: d.doc.mode)
    }

    /// The `eyedropper` param of `layer.setAdjustment` on Levels or Curves adjustment layer `layer`:
    /// the Properties panel's Set Black/Neutral Gray/White Point pickers. `at` samples the image the
    /// layer adjusts (the composite with the layer hidden, like its Properties histogram), so clicking
    /// the same pixel again maps it the same way. The picker edits the layer's adjustment with the
    /// other keys of `p` merged over it. nil without the key.
    public static func layerEyedropper(_ s: Session, layer: LayerId, _ p: JSONValue) throws -> Adjustment? {
        guard let e = p["eyedropper"] else { return nil }
        guard let d = s.active else { throw EngineError.noDocument }
        guard let l = d.doc.layer(layer) else { throw EngineError.noLayer(layer) }
        let kind: String, adj: Adjustment
        switch l.content {
        case .adjustment(let a):
            switch a {
            case .curves: (kind, adj) = ("curves", a)
            case .levels: (kind, adj) = ("levels", a)
            default: throw EngineError.bad(eyedropper, "`eyedropper` applies to Levels and Curves adjustment layers only")
            }
        default:
            throw EngineError.bad(eyedropper, "`eyedropper` applies to Levels and Curves adjustment layers only")
        }
        let rest = p.removing("eyedropper")
        let current = userKeys(rest).isEmpty ? adj : try fromParams(kind, rest, base: adj, mode: d.doc.mode)
        let (picker, sample) = try eyedropperSample(s.services.renderer, d.doc, hide: layer, e)
        return try adjustmentEyedropper(kind, toParams(current), picker, sample, mode: d.doc.mode)
    }

    /// The picker and sample of an `eyedropper` param; `at` samples `doc` with layer `hide` hidden.
    static func eyedropperSample(_ renderer: EngineRenderer, _ doc: Document, hide: LayerId?, _ e: JSONValue) throws -> (CurvesEyedropper, SIMD3<Float>) {
        let cmd = eyedropper
        let picker: CurvesEyedropper
        switch e["point"]?.stringValue {
        case "black"?: picker = .black
        case "gray"?: picker = .neutralGray
        case "white"?: picker = .white
        default: throw EngineError.bad(cmd, "`eyedropper.point` must be \"black\", \"gray\" or \"white\"")
        }
        if let c = e["color"] {
            guard let a = c.arrayValue, a.count == 3, let r = a[0].doubleValue, let g = a[1].doubleValue, let b = a[2].doubleValue else {
                throw EngineError.bad(cmd, "`eyedropper.color` must be [r, g, b] in 0..1")
            }
            return (picker, SIMD3(Float(r), Float(g), Float(b)))
        }
        guard let at = e["at"] else { throw EngineError.bad(cmd, "`eyedropper` needs `at` [x, y] or `color` [r, g, b]") }
        guard let a = at.arrayValue, a.count == 2, let x = a[0].doubleValue, let y = a[1].doubleValue, x.isFinite, y.isFinite else {
            throw EngineError.bad(cmd, "`eyedropper.at` must be [x, y] in document pixels")
        }
        let (w, h) = (Double(doc.size.width), Double(doc.size.height))
        if x < 0 || y < 0 || x >= w || y >= h { throw EngineError.bad(cmd, "`eyedropper.at` is outside the image") }
        let size = try sizeParam(cmd, e)
        var src = doc
        if let id = hide { src.updateLayer(id) { $0.visible = false } }
        let px = try sampleColor(renderer, src, x, y, size)
        if px.w <= 0 { throw EngineError.bad(cmd, "the sampled pixel is transparent") }
        return (picker, SIMD3(px.x, px.y, px.z))
    }

    /// The `size` param: 1 (Point Sample) or an averaged square's side; "point" is accepted too
    /// (photocraft `sample_cmds::size_param`).
    static func sizeParam(_ cmd: String, _ p: JSONValue) throws -> UInt32 {
        switch p["size"] {
        case nil, .null?: return 1
        case .string("point")?: return 1
        case let v?:
            guard let n = v.uint64Value, let s = UInt32(exactly: n), sampleSizes.contains(s) else {
                throw EngineError.bad(cmd, "`size` = \(v.serialized()) must be \"point\" or one of [\(sampleSizes.map(String.init).joined(separator: ", "))]")
            }
            return s
        }
    }

    /// The colour the Eyedropper picks from the whole composite at document point (x, y) with
    /// Sample Size `size` (photocraft `sample_cmds::sample_color` with `SampleLayers::All`): a Point
    /// Sample is the composite pixel itself; larger sizes are the alpha-weighted average of the
    /// square around it, clipped to the canvas, taken in the document's channels.
    static func sampleColor(_ renderer: EngineRenderer, _ doc: Document, _ x: Double, _ y: Double, _ size: UInt32) throws -> SIMD4<Float> {
        let canvas = doc.bounds
        guard x.isFinite, y.isFinite, sampleSizes.contains(size) else { return .zero }
        let (fx, fy) = (x.rounded(.down), y.rounded(.down))
        guard fx >= Double(Int32.min), fx <= Double(Int32.max), fy >= Double(Int32.min), fy <= Double(Int32.max) else { return .zero }
        let (px, py) = (Int32(fx), Int32(fy))
        guard px >= canvas.x0, px < canvas.x1, py >= canvas.y0, py < canvas.y1 else { return .zero }
        let r = Int32(size / 2)
        let (ix, iy, ir) = (Int(px), Int(py), Int(r))
        let square = PixelRect(x0: Int32(clamping: ix - ir), y0: Int32(clamping: iy - ir), x1: Int32(clamping: ix + ir + 1), y1: Int32(clamping: iy + ir + 1)).intersect(canvas)
        if square.isEmpty { return .zero }
        let buf = try renderer.renderExact(doc, region: square)
        if size == 1 { return buf.px.first ?? .zero }
        // CMYK documents are composited in RGB: their composite RGB is averaged.
        let mode = doc.pixelFormat.mode == .cmyk ? ColorMode.rgb : doc.pixelFormat.mode
        return average(buf.px, mode, doc.depth)
    }

    /// Rounds `v` to what a channel of `depth` can store (32 bit keeps the float).
    static func quantize(_ v: Float, _ depth: SampleType) -> Float {
        switch depth {
        case .u8: return v.isNaN ? 0 : (clamp(v, 0, 1) * 255 + 0.5).rounded(.down) / 255
        case .u16: return v.isNaN ? 0 : (clamp(v, 0, 1) * 65535 + 0.5).rounded(.down) / 65535
        case .f32: return v
        }
    }

    /// The alpha-weighted average of straight-alpha RGBA pixels in the channels of `mode` at
    /// `depth` (photocraft `sample_cmds::average`).
    static func average(_ px: [SIMD4<Float>], _ mode: ColorMode, _ depth: SampleType) -> SIMD4<Float> {
        let fmt = PixelFormat(mode: mode, sample: depth, alpha: false)
        let n = Swift.min(fmt.channels, 8)
        var sum = [Double](repeating: 0, count: 8)
        var alpha = 0.0
        for p in px {
            let a = p.w.isFinite ? clamp(p.w, 0, 1) : 0
            if a <= 0 || !(p.x.isFinite && p.y.isFinite && p.z.isFinite) { continue }
            let native = fmt.components(fromRGBA: p)
            for k in 0..<Swift.min(n, native.count) { sum[k] += Double(native[k]) * Double(a) }
            alpha += Double(a)
        }
        if px.isEmpty || alpha <= 0 { return .zero }
        let mean = (0..<n).map { quantize(Float(sum[$0] / alpha), depth) }
        let c = PixelCodec.toRGBA(fmt, mean)
        return SIMD4(c.x, c.y, c.z, quantize(Float(alpha / Double(px.count)), depth))
    }
}
