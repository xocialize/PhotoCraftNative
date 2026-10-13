// Port of photocraft-engine (crates/engine/src/layer_style.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Layer › Layer Style: `layer.layerStyle.<kind>` adds or replaces one layer effect (Drop Shadow …
// Satin, Bevel & Emboss) from params in Photoshop units, `layer.layerStyle.replace` applies the
// Layer Style dialog's whole effect list in one step, Make Default / Reset to Default keep the
// user defaults (session state, see `PresetCommands`), and Clear removes a style or one effect.
// The JSON params ⇄ `Effect` mapping and the built-in contour presets live here too; Blending
// Options are `layer_menu_cmds`'.

import Foundation
import PCDocument
import PCFoundation
import PCPSD

public enum LayerStyleCommands: CommandModule {
    public static let name = "layer_style"
    static let m = name

    public static func register(into r: inout CommandRegistry) {
        r.add(specs())
    }

    // MARK: Param helpers

    /// photocraft `gradient_style`: a gradient style name (`linear` when unknown).
    static func gradientStyle(_ s: String) -> GradientStyle {
        switch s.lowercased() {
        case "radial": .radial
        case "angle": .angle
        case "reflected": .reflected
        case "diamond": .diamond
        default: .linear
        }
    }

    static func f(_ p: JSONValue, _ k: String, _ d: Float) -> Float { p[k]?.doubleValue.map { Float($0) } ?? d }
    static func b(_ p: JSONValue, _ k: String, _ d: Bool) -> Bool { p[k]?.boolValue ?? d }
    static func fOf(_ p: JSONValue, _ k: String) -> Float? { p[k]?.doubleValue.map { Float($0) } }
    static func bOf(_ p: JSONValue, _ k: String) -> Bool? { p[k]?.boolValue }

    /// Rust `u8::from_str_radix` of the two bytes at `i` (nil when out of range or not hex).
    static func hexPair(_ b: [UInt8], _ i: Int) -> UInt8? {
        guard i >= 0, i + 2 <= b.count else { return nil }
        func digit(_ c: UInt8) -> UInt8? {
            switch c {
            case 48...57: c - 48
            case 65...70: c - 55
            case 97...102: c - 87
            default: nil
            }
        }
        if b[i] == 43 { return digit(b[i + 1]) }  // a leading "+" is accepted by from_str_radix
        guard let hi = digit(b[i]), let lo = digit(b[i + 1]) else { return nil }
        return hi * 16 + lo
    }

    /// The UTF-8 bytes of `s` with every leading `#` removed (Rust `trim_start_matches('#')`).
    static func hexBytes(_ s: String) -> [UInt8] { Array(s.utf8.drop { $0 == 35 }) }

    /// photocraft `color_of`: `[r,g,b]` (missing components 0) or `"#rrggbb"` (unparseable pairs 0).
    static func colorOf(_ p: JSONValue, _ k: String) -> PCColor? {
        switch p[k] {
        case .array(let a)? where a.count >= 3:
            return .rgb(Float(a[0].doubleValue ?? 0), Float(a[1].doubleValue ?? 0), Float(a[2].doubleValue ?? 0))
        case .string(let s)?:
            let h = hexBytes(s)
            func c(_ i: Int) -> Float { hexPair(h, i).map { Float($0) / 255 } ?? 0 }
            return h.count >= 6 ? .rgb(c(0), c(2), c(4)) : nil
        default:
            return nil
        }
    }

    static func color(_ p: JSONValue, _ k: String, _ d: SIMD3<Float>) -> PCColor {
        let c = colorOf(p, k)?.rgb ?? d
        return .rgb(c.x, c.y, c.z)
    }

    static func gradient(_ p: JSONValue) -> StyleGradient {
        StyleGradient(stops: [ColorStop(0, color(p, "from", .zero)), ColorStop(1, color(p, "to", SIMD3(repeating: 1)))],
                      style: gradientStyle(p["style"]?.stringValue ?? "linear"), angle: f(p, "angle", 90),
                      scale: f(p, "scale", 100) / 100, reverse: b(p, "reverse", false))
    }

    static func clamp(_ v: Float, _ lo: Float, _ hi: Float) -> Float { min(max(v, lo), hi) }

    // MARK: Factory defaults

    /// photocraft `effect_defaults`: factory defaults for each effect kind, in the command's
    /// parameter units (what the Layer Style dialog starts a new effect from).
    static func effectDefaults(_ kind: String) -> JSONValue {
        switch kind {
        case "dropShadow":
            ["blend": "Multiply", "color": "#000000", "opacity": 75, "angle": 120, "useGlobalLight": true, "distance": 5, "spread": 0, "size": 5,
             "contour": "Linear", "antiAlias": false, "noise": 0, "knocksOut": true]
        case "innerShadow":
            ["blend": "Multiply", "color": "#000000", "opacity": 75, "angle": 120, "useGlobalLight": true, "distance": 5, "choke": 0, "size": 5,
             "contour": "Linear", "antiAlias": false, "noise": 0]
        case "outerGlow":
            ["blend": "Screen", "opacity": 75, "color": "#ffffbe", "spread": 0, "size": 5, "range": 50, "contour": "Linear", "antiAlias": false, "noise": 0]
        case "innerGlow":
            ["blend": "Screen", "opacity": 75, "color": "#ffffbe", "source": "edge", "choke": 0, "size": 5, "contour": "Linear", "antiAlias": false, "noise": 0]
        case "stroke":
            ["size": 3, "position": "outside", "blend": "Normal", "opacity": 100, "color": "#000000"]
        case "colorOverlay":
            ["blend": "Normal", "color": "#ff0000", "opacity": 100]
        case "gradientOverlay":
            ["blend": "Normal", "opacity": 100, "from": "#000000", "to": "#ffffff", "reverse": false, "style": "linear", "angle": 90, "scale": 100]
        case "patternOverlay":
            ["blend": "Normal", "opacity": 100, "pattern": "", "angle": 0, "scale": 100, "link": true]
        case "bevelEmboss":
            ["style": "inner", "depth": 100, "direction": "up", "size": 5, "soften": 0, "angle": 120, "useGlobalLight": true, "altitude": 30,
             "glossContour": "Linear", "contour": false, "contourName": "Linear", "contourRange": 50, "contourAntiAlias": false]
        case "satin":
            ["blend": "Multiply", "color": "#000000", "opacity": 50, "angle": 19, "distance": 11, "size": 14, "contour": "Linear", "antiAlias": true, "invert": true]
        default:
            .object([:])
        }
    }

    // MARK: Contours

    /// A contour preset point: input, output (both `0...1`) and whether it is a corner.
    typealias ContourPoint = (Float, Float, Bool)

    /// Built-in contour presets, in the order of Photoshop's default contour picker, re-measured
    /// from Photoshop 27.11's renders (PCRender phase 5, batch M2 item 7; no curve was read from
    /// Photoshop or from any file):
    /// - **0 … 0.496** (every preset): a Precise Outer Glow (size 120, range 100 %) of each preset,
    ///   Anti-aliased off, round a square on black. Along the square's sides each pixel's glow
    ///   value is v = ½ (1 − (d + ½)/121), so a side pixel reads the contour at v directly (no
    ///   spread along the sides); the samples are thinned to within 0.75 level. The renders reproduce
    ///   Linear at Range 50 % within 1 level and Photoshop's own Cone, Gaussian and Ring curves
    ///   within 0.3–0.6 level mean.
    /// - **Above 0.496**, and where Precise Glow's outer fade hides the curve (Cone − Inverted below
    ///   0.091, Cove − Deep 0.033, Cove − Shallow 0.062, Rolling Slope 0.087): photocraft's earlier
    ///   Satin-based measurement, shifted by the constant offset that best matches the new lower
    ///   half (Satin is blind to a constant: Rounded Steps' old curve sat 0.23 high). Range 100 %
    ///   renders cannot see a contour above ½; this half awaits a Range 50 % re-measurement, and on
    ///   the Satin maps it is the half that misses (Cone / Ring 1.1–1.3 levels mean).
    /// Points are joined by straight segments (inner points corners), except Cone, which is smooth
    /// as Photoshop stores it. Imported PSD contours keep their own points.
    static let contours: [(String, [ContourPoint])] = [
        ("Linear", [(0.0, 0.0, false), (1.0, 1.0, false)]),
        ("Cone", [(0.0, 0.0, false), (0.0413, 0.1255, false), (0.0455, 0.1412, false), (0.1529, 0.4471, false), (0.2107, 0.5961, false), (0.2686, 0.7294, false), (0.3306, 0.8471, false), (0.3471, 0.8745, false), (0.3843, 0.9255, false), (0.4298, 0.9725, false), (0.4463, 0.9843, false), (0.4835, 1.0, false), (0.523, 1.0, false), (0.57, 0.9808, false), (0.664, 0.8708, false), (0.703, 0.8008, false), (0.742, 0.7228, false), (0.836, 0.4888, false), (0.859, 0.4098, false), (0.914, 0.2778, false), (0.945, 0.1678, false), (0.977, 0.0898, false), (1.0, 0.0, false)]),
        ("Cone - Inverted", [(0.0, 1.0, false), (0.031, 0.9096, true), (0.07, 0.7766, true), (0.0909, 0.7255, true), (0.1653, 0.5176, true), (0.2273, 0.3608, true), (0.2769, 0.251, true), (0.343, 0.1294, true), (0.3884, 0.0667, true), (0.4339, 0.0235, true), (0.4587, 0.0078, true), (0.4835, 0.0, true), (0.523, 0.0, true), (0.57, 0.0186, true), (0.664, 0.1286, true), (0.703, 0.1986, true), (0.742, 0.2766, true), (0.836, 0.5106, true), (0.859, 0.5896, true), (0.914, 0.7216, true), (0.945, 0.8316, true), (0.977, 0.9096, true), (1.0, 1.0, false)]),
        ("Cove - Deep", [(0.0, 0.2558, false), (0.3719, 0.2902, true), (0.4463, 0.3294, true), (0.4876, 0.3569, true), (0.57, 0.4278, true), (0.617, 0.4818, true), (0.664, 0.5678, true), (0.703, 0.7088, true), (0.742, 0.9038, true), (0.773, 0.9978, true), (1.0, 1.0, false)]),
        ("Cove - Shallow", [(0.0, 0.0, false), (0.008, 0.165, true), (0.016, 0.478, true), (0.039, 0.509, true), (0.062, 0.5137, true), (0.1529, 0.5608, true), (0.2107, 0.6, true), (0.2686, 0.651, true), (0.2727, 0.6588, true), (0.314, 0.702, true), (0.3802, 0.7922, true), (0.4421, 0.8902, true), (0.4959, 0.9843, true), (0.523, 1.0, true), (1.0, 1.0, false)]),
        ("Gaussian", [(0.0, 0.0, false), (0.0702, 0.0078, true), (0.1281, 0.0275, true), (0.1653, 0.051, true), (0.2231, 0.1098, true), (0.2727, 0.1843, true), (0.314, 0.2627, true), (0.4174, 0.4863, true), (0.4835, 0.6196, true), (0.4876, 0.6235, true), (0.523, 0.6903, true), (0.617, 0.8143, true), (0.703, 0.8933, true), (0.805, 0.9553, true), (1.0, 1.0, false)]),
        ("Half Round", [(0.0, 0.0, false), (0.0537, 0.1412, true), (0.1033, 0.2588, true), (0.1529, 0.3647, true), (0.1901, 0.4353, true), (0.2521, 0.5373, true), (0.3017, 0.6078, true), (0.3595, 0.6784, true), (0.3843, 0.702, true), (0.3884, 0.7098, true), (0.4545, 0.7725, true), (0.4876, 0.7961, true), (0.523, 0.8315, true), (0.617, 0.8865, true), (0.773, 0.9485, true), (1.0, 1.0, false)]),
        ("Ring", [(0.0, 0.0, false), (0.0372, 0.1176, true), (0.0785, 0.2549, true), (0.1198, 0.4118, true), (0.1405, 0.498, true), (0.1653, 0.6118, true), (0.1942, 0.7373, true), (0.2107, 0.8039, true), (0.2273, 0.8627, true), (0.2397, 0.902, true), (0.2562, 0.9451, true), (0.2769, 0.9804, true), (0.2975, 1.0, true), (0.3264, 1.0, true), (0.3471, 0.9843, true), (0.3636, 0.9608, true), (0.3843, 0.9216, true), (0.4008, 0.8824, true), (0.4256, 0.8118, true), (0.4587, 0.702, true), (0.57, 0.2902, true), (0.617, 0.1502, true), (0.664, 0.0642, true), (0.703, 0.0252, true), (0.742, 0.0252, true), (0.773, 0.0712, true), (0.836, 0.2432, true), (0.859, 0.3532, true), (0.891, 0.4542, true), (0.914, 0.5562, true), (0.945, 0.7432, true), (0.977, 0.8842, true), (1.0, 1.0, false)]),
        ("Ring - Double", [(0.0, 0.0, false), (0.0331, 0.051, true), (0.0661, 0.1137, true), (0.0992, 0.2, true), (0.1198, 0.2706, true), (0.1405, 0.3569, true), (0.1612, 0.4549, true), (0.1942, 0.6235, true), (0.2273, 0.7765, true), (0.2438, 0.8392, true), (0.2645, 0.898, true), (0.281, 0.9294, true), (0.2934, 0.9412, true), (0.3099, 0.9412, true), (0.3264, 0.9216, true), (0.3306, 0.9137, true), (0.3471, 0.8667, true), (0.3595, 0.8196, true), (0.3678, 0.7804, true), (0.3802, 0.7098, true), (0.3926, 0.6275, true), (0.4132, 0.4745, true), (0.4339, 0.3137, true), (0.4587, 0.1451, true), (0.4628, 0.1216, true), (0.4752, 0.0627, true), (0.4876, 0.0196, true), (0.4959, 0.0039, true), (0.523, 0.0501, true), (0.57, 0.3231, true), (0.617, 0.6511, true), (0.664, 0.8701, true), (0.703, 0.9331, true), (0.742, 0.8551, true), (0.773, 0.6441, true), (0.805, 0.3781, true), (0.836, 0.1591, true), (0.859, 0.0341, true), (0.891, 0.0261, true), (0.914, 0.1121, true), (0.977, 0.7061, true), (0.984, 0.8231, true), (1.0, 1.0, false)]),
        ("Rolling Slope - Descending", [(0.0, 1.0, false), (0.008, 0.995, true), (0.031, 0.925, true), (0.039, 0.878, true), (0.07, 0.753, true), (0.0868, 0.702, true), (0.095, 0.6706, true), (0.1157, 0.6039, true), (0.1529, 0.498, true), (0.1694, 0.4588, true), (0.1983, 0.4039, true), (0.2149, 0.3804, true), (0.2314, 0.3647, true), (0.2521, 0.3529, true), (0.2686, 0.3529, true), (0.2727, 0.349, true), (0.2769, 0.3529, true), (0.2934, 0.3529, true), (0.3347, 0.3765, true), (0.3967, 0.4353, true), (0.4008, 0.4431, true), (0.4256, 0.4667, true), (0.4587, 0.5059, true), (0.4959, 0.5412, true), (0.523, 0.565, true), (0.57, 0.597, true), (0.617, 0.612, true), (0.703, 0.597, true), (0.742, 0.557, true), (0.836, 0.386, true), (0.914, 0.206, true), (0.945, 0.104, true), (0.977, 0.034, true), (0.984, 0.003, true), (1.0, 0.0, false)]),
        ("Rounded Steps", [(0.0, 0.0, false), (0.0455, 0.1176, true), (0.0744, 0.1725, true), (0.1033, 0.2118, true), (0.1364, 0.2392, true), (0.1612, 0.251, true), (0.1777, 0.2549, true), (0.2314, 0.2549, true), (0.2479, 0.251, true), (0.2521, 0.2549, true), (0.2769, 0.3137, true), (0.3058, 0.3725, true), (0.3099, 0.3843, true), (0.3471, 0.4431, true), (0.3802, 0.4745, true), (0.4091, 0.4902, true), (0.4421, 0.4941, true), (0.4463, 0.498, true), (0.4959, 0.4941, true), (0.523, 0.5655, true), (0.57, 0.6665, true), (0.617, 0.7215, true), (0.664, 0.7525, true), (0.773, 0.7525, true), (0.836, 0.6745, true), (0.891, 0.6595, true), (0.914, 0.6665, true), (1.0, 0.7685, false)]),
        ("Sawtooth 1", [(0.0, 0.0, false), (0.1942, 0.3765, true), (0.2066, 0.4039, true), (0.2562, 0.498, true), (0.2603, 0.498, true), (0.4959, 0.0039, true), (0.742, 0.4718, true), (0.773, 0.4478, true), (0.914, 0.1828, true), (0.945, 0.1048, true), (1.0, 0.0, false)]),
    ]

    /// Names earlier versions offered, still accepted by `contour` params (scripts, saved defaults).
    static let legacyContours: [(String, [ContourPoint])] = [
        ("Cone (Inverted)", [(0.0, 1.0, false), (0.5, 0.0, false), (1.0, 0.0, false)]),
        ("Domed", [(0.0, 0.0, false), (0.25, 1.0, false), (0.75, 1.0, false), (1.0, 0.0, false)]),
        ("Domed (Inverted)", [(0.0, 1.0, false), (0.25, 0.0, false), (0.75, 0.0, false), (1.0, 1.0, false)]),
        ("Diagonal (Descending)", [(0.0, 1.0, false), (1.0, 0.0, false)]),
    ]

    /// Most points a contour param may carry.
    static let maxContourPoints = 64

    static func presetContour(_ name: String, _ pts: [ContourPoint]) -> Contour {
        let corners = pts.map(\.2)
        return .custom(Contour.CustomContour(name: name, points: pts.map { CurvePoint(input: $0.0, output: $0.1) },
                                             corners: corners.contains(true) ? corners : []))
    }

    /// photocraft `builtin_contour`: the built-in contour called `name` (`Linear` is the identity);
    /// nil for names we don't ship, so imported contours are carried rather than clobbered.
    static func builtinContour(_ name: String) -> Contour? {
        if name.lowercased() == "linear" && name.allSatisfy(\.isASCII) { return .linear }
        guard let (n, pts) = (contours.dropFirst() + legacyContours).first(where: { $0.0 == name }) else { return nil }
        return presetContour(n, pts)
    }

    /// photocraft `contour_param`: `"Linear"` or a built-in preset's name when the contour is that
    /// preset, else the curve itself as `{"name", "points": [[input, output], …], "corners": […]}`.
    static func contourParam(_ c: Contour) -> JSONValue {
        switch c {
        case .linear:
            return "Linear"
        case .custom(let cc):
            if builtinContour(cc.name) == c { return .string(cc.name) }
            let pts: [JSONValue] = cc.points.map { [short($0.input), short($0.output)] }
            let corners: [JSONValue] = cc.points.indices.map { .bool($0 < cc.corners.count ? cc.corners[$0] : false) }
            return ["name": .string(cc.name), "points": .array(pts), "corners": .array(corners)]
        }
    }

    /// `x` as the shortest decimal that reads back as the same `Float` (`0.2`, not `0.20000000298…`).
    static func short(_ x: Float) -> JSONValue {
        guard x.isFinite, let v = Double("\(x)") else { return .null }
        return .number(v)
    }

    /// The contours of an `.shc` contour preset file (Contour Editor › Load…), as `contour`
    /// params. Points are rescaled from the file's 0…255 levels; unusable curves are skipped
    /// (photocraft `contours_from_shc`).
    public static func contoursFromShc(_ bytes: [UInt8]) throws -> [JSONValue] {
        let file: [PSDShc.Contour]
        do { file = try PSDShc.parse(Data(bytes)) } catch { throw EngineError.other("not a contour file: \(error)") }
        return file.compactMap { c in
            let v: JSONValue = [
                "name": .string(c.name),
                "points": .array(c.points.map { [.number(Double($0.input / 255)), .number(Double($0.output / 255))] }),
                "corners": .array(c.points.map { .bool(!$0.continuous) }),
            ]
            return contourFromParam(v).map(contourParam)
        }
    }

    /// An `.shc` file holding `contour` (Contour Editor › Save…) (photocraft `contour_to_shc`).
    public static func contourToShc(_ contour: Contour) throws -> [UInt8] {
        let name: String, points: [CurvePoint], corners: [Bool]
        switch contour {
        case .linear: (name, points, corners) = ("Linear", [CurvePoint(input: 0, output: 0), CurvePoint(input: 1, output: 1)], [])
        case .custom(let c): (name, points, corners) = (c.name, c.points, c.corners)
        }
        let pts = points.enumerated().map { i, p in
            PSDShc.Point(input: p.input * 255, output: p.output * 255, continuous: !(i < corners.count && corners[i]))
        }
        do { return [UInt8](try PSDShc.write([PSDShc.Contour(name: name, points: pts)])) } catch {
            throw EngineError.other("can't write the contour: \(error)")
        }
    }

    /// photocraft `contour_from_param`: a built-in preset's name, or a curve object (see
    /// `contourParam`). nil for an unknown name or a malformed curve (fewer than two points, more
    /// than `maxContourPoints`, non-finite values). Points are clamped to `0...1` and sorted by
    /// input; points at the same input collapse.
    static func contourFromParam(_ v: JSONValue) -> Contour? {
        switch v {
        case .string(let name):
            return builtinContour(name)
        case .object(let o):
            guard let raw = o["points"]?.arrayValue else { return nil }
            if raw.count < 2 || raw.count > maxContourPoints { return nil }
            let flags = o["corners"]?.arrayValue
            var pts: [ContourPoint] = []
            for (i, q) in raw.enumerated() {
                guard let q = q.arrayValue, let x0 = q.first?.doubleValue, q.count > 1, let y0 = q[1].doubleValue else { return nil }
                let (x, y) = (Float(x0), Float(y0))
                if !x.isFinite || !y.isFinite { return nil }
                let corner = flags.flatMap { i < $0.count ? $0[i].boolValue : nil } ?? false
                pts.append((clamp(x, 0, 1), clamp(y, 0, 1), corner))
            }
            // Stable sort by input (Rust `sort_by`), then `dedup_by` against the last kept point.
            pts = pts.enumerated().sorted { $0.element.0 != $1.element.0 ? $0.element.0 < $1.element.0 : $0.offset < $1.offset }.map(\.element)
            var kept: [ContourPoint] = []
            for p in pts where !(kept.last.map { abs(p.0 - $0.0) < 1e-6 } ?? false) { kept.append(p) }
            if kept.count < 2 { return nil }
            return presetContour(o["name"]?.stringValue ?? "Custom", kept)
        default:
            return nil
        }
    }

    // MARK: Params ⇄ effects

    /// An effect of `kind` with its factory settings (before params are applied).
    static func freshEffect(_ kind: String) -> Effect? {
        func shadow(_ inner: Bool) -> Shadow {
            Shadow(common: FxCommon(.multiply, 0.75), color: .black, angle: 120, useGlobalLight: true, distance: 5, spread: 0, size: 5,
                   contour: .linear, antiAlias: false, noise: 0, knocksOut: !inner)
        }
        func glow() -> Glow {
            Glow(common: FxCommon(.screen, 0.75), paint: .color(.rgb(1, 1, 190 / 255)), technique: .softer, spread: 0, size: 5, contour: .linear,
                 antiAlias: false, range: 0.5, jitter: 0, noise: 0, source: .edge)
        }
        switch kind {
        case "dropShadow": return .dropShadow(shadow(false))
        case "innerShadow": return .innerShadow(shadow(true))
        case "outerGlow": return .outerGlow(glow())
        case "innerGlow": return .innerGlow(glow())
        case "stroke": return .stroke(StrokeFx(common: FxCommon(.normal, 1), size: 3, position: .outside, paint: .color(.rgb(1, 0, 0))))
        case "colorOverlay": return .colorOverlay(Effect.ColorOverlay(common: FxCommon(.normal, 1), color: .rgb(1, 0, 0)))
        case "gradientOverlay": return .gradientOverlay(Effect.GradientOverlay(common: FxCommon(.normal, 1), gradient: StyleGradient(), dither: false))
        case "patternOverlay":
            return .patternOverlay(Effect.PatternOverlay(common: FxCommon(.normal, 1), name: "", id: "", scale: 1, angle: 0, link: true, phase: .zero))
        case "satin":
            return .satin(Satin(common: FxCommon(.multiply, 0.5), color: .black, angle: 19, distance: 11, size: 14, contour: .linear, antiAlias: true, invert: true))
        case "bevelEmboss":
            return .bevelEmboss(Bevel(enabled: true, style: .innerBevel, technique: .smooth, depth: 1, up: true, size: 5, soften: 0, angle: 120, altitude: 30,
                                      useGlobalLight: true, glossContour: .linear, highlight: FxCommon(.screen, 0.75), highlightColor: .white,
                                      shadow: FxCommon(.multiply, 0.75), shadowColor: .black, contour: nil, texture: nil))
        default: return nil
        }
    }

    /// Edits an existing gradient in place: only the end colours and geometry. Intermediate stops,
    /// opacity stops, alignment and offset survive a round trip.
    static func overlayGradient(_ g: inout StyleGradient, _ p: JSONValue) {
        if let c = colorOf(p, "from"), !g.stops.isEmpty { g.stops[0].color = c }
        if let c = colorOf(p, "to"), !g.stops.isEmpty { g.stops[g.stops.count - 1].color = c }
        if let s = p["style"]?.stringValue { g.style = gradientStyle(s) }
        if let x = fOf(p, "angle") { g.angle = x }
        if let x = fOf(p, "scale") { g.scale = clamp(x / 100, 0.01, 10) }
        if let x = bOf(p, "reverse") { g.reverse = x }
    }

    static func overlayCommon(_ c: inout FxCommon, _ p: JSONValue) {
        if let x = bOf(p, "enabled") { c.enabled = x }
        if let x = p["blend"]?.stringValue.flatMap(Params.blendMode) { c.blend = x }
        if let x = fOf(p, "opacity") { c.opacity = clamp(x / 100, 0, 1) }
    }

    static func setContour(_ p: JSONValue, _ key: String, _ c: inout Contour) {
        if let x = p[key].flatMap(contourFromParam) { c = x }
    }

    /// photocraft `overlay_effect`: applies the params present in `p` onto an existing effect, in
    /// the command's parameter units. Absent (or unparseable) keys leave the effect unchanged, so a
    /// dialog round trip never touches what it doesn't model: an imported gradient stroke keeps
    /// its gradient while its opacity is edited.
    static func overlayEffect(_ fx: inout Effect, _ p: JSONValue) {
        func shadow(_ s: inout Shadow, inner: Bool) {
            overlayCommon(&s.common, p)
            if let x = colorOf(p, "color") { s.color = x }
            if let x = fOf(p, "angle") { s.angle = x }
            if let x = bOf(p, "useGlobalLight") { s.useGlobalLight = x }
            if let x = fOf(p, "distance") { s.distance = x }
            if let x = fOf(p, inner ? "choke" : "spread") { s.spread = clamp(x / 100, 0, 1) }
            if let x = fOf(p, "size") { s.size = x }
            setContour(p, "contour", &s.contour)
            if let x = bOf(p, "antiAlias") { s.antiAlias = x }
            if let x = fOf(p, "noise") { s.noise = clamp(x / 100, 0, 1) }
            if !inner, let x = bOf(p, "knocksOut") { s.knocksOut = x }
        }
        func glow(_ g: inout Glow, inner: Bool) {
            overlayCommon(&g.common, p)
            if let c = colorOf(p, "color") { g.paint = .color(c) }
            if let t = p["technique"]?.stringValue { g.technique = t == "precise" ? .precise : .softer }
            if let x = fOf(p, inner ? "choke" : "spread") { g.spread = clamp(x / 100, 0, 1) }
            if let x = fOf(p, "size") { g.size = x }
            setContour(p, "contour", &g.contour)
            if let x = bOf(p, "antiAlias") { g.antiAlias = x }
            if let x = fOf(p, "range") { g.range = clamp(x / 100, 0.01, 1) }
            if let x = fOf(p, "noise") { g.noise = clamp(x / 100, 0, 1) }
            if inner, let s = p["source"]?.stringValue { g.source = s == "center" ? .center : .edge }
        }
        switch fx {
        case .dropShadow(var s):
            shadow(&s, inner: false)
            fx = .dropShadow(s)
        case .innerShadow(var s):
            shadow(&s, inner: true)
            fx = .innerShadow(s)
        case .outerGlow(var g):
            glow(&g, inner: false)
            fx = .outerGlow(g)
        case .innerGlow(var g):
            glow(&g, inner: true)
            fx = .innerGlow(g)
        case .stroke(var s):
            overlayCommon(&s.common, p)
            if let x = fOf(p, "size") { s.size = x }
            if let pos = p["position"]?.stringValue {
                s.position = switch pos {
                case "inside": .inside
                case "center": .center
                default: .outside
                }
            }
            if p["from"] != nil {
                s.paint = .gradient(gradient(p))
            } else if let c = colorOf(p, "color") {
                s.paint = .color(c)
            }
            fx = .stroke(s)
        case .colorOverlay(var o):
            overlayCommon(&o.common, p)
            if let x = colorOf(p, "color") { o.color = x }
            fx = .colorOverlay(o)
        case .gradientOverlay(var o):
            overlayCommon(&o.common, p)
            overlayGradient(&o.gradient, p)
            if let x = bOf(p, "dither") { o.dither = x }
            fx = .gradientOverlay(o)
        case .patternOverlay(var o):
            overlayCommon(&o.common, p)
            if let x = p["pattern"]?.stringValue {
                o.name = x
                o.id = ""
            }
            if let x = fOf(p, "scale") { o.scale = clamp(x / 100, 0.01, 10) }
            if let x = fOf(p, "angle") { o.angle = x }
            if let x = bOf(p, "link") { o.link = x }
            if let x = fOf(p, "phaseX") { o.phase.x = x }
            if let x = fOf(p, "phaseY") { o.phase.y = x }
            fx = .patternOverlay(o)
        case .satin(var s):
            overlayCommon(&s.common, p)
            if let x = colorOf(p, "color") { s.color = x }
            if let x = fOf(p, "angle") { s.angle = x }
            if let x = fOf(p, "distance") { s.distance = x }
            if let x = fOf(p, "size") { s.size = x }
            if let x = bOf(p, "invert") { s.invert = x }
            setContour(p, "contour", &s.contour)
            if let x = bOf(p, "antiAlias") { s.antiAlias = x }
            fx = .satin(s)
        case .bevelEmboss(var bv):
            if let x = bOf(p, "enabled") { bv.enabled = x }
            if let s = p["style"]?.stringValue {
                bv.style = switch s {
                case "outer": .outerBevel
                case "emboss": .emboss
                case "pillow": .pillowEmboss
                case "stroke": .strokeEmboss
                default: .innerBevel
                }
            }
            if let t = p["technique"]?.stringValue {
                bv.technique = switch t {
                case "chiselHard": .chiselHard
                case "chiselSoft": .chiselSoft
                default: .smooth
                }
            }
            if let x = fOf(p, "depth") { bv.depth = x / 100 }
            if let d = p["direction"]?.stringValue { bv.up = d != "down" }
            if let x = fOf(p, "size") { bv.size = x }
            if let x = fOf(p, "soften") { bv.soften = x }
            if let x = fOf(p, "angle") { bv.angle = x }
            if let x = fOf(p, "altitude") { bv.altitude = x }
            if let x = bOf(p, "useGlobalLight") { bv.useGlobalLight = x }
            setContour(p, "glossContour", &bv.glossContour)
            // The Contour element: `contour` turns it on/off; its curve, Range and Anti-aliased
            // edit the element in place, so an imported curve survives.
            switch bOf(p, "contour") {
            case false?: bv.contour = nil
            case true? where bv.contour == nil: bv.contour = BevelContour()
            default: break
            }
            if var c = bv.contour {
                setContour(p, "contourName", &c.contour)
                if let x = fOf(p, "contourRange") { c.range = clamp(x / 100, 0.01, 1) }
                if let x = bOf(p, "contourAntiAlias") { c.antiAlias = x }
                bv.contour = c
            }
            if let t = p["texture"]?.stringValue, !t.isEmpty {
                bv.texture = BevelTexture(name: t, id: t, scale: clamp(f(p, "textureScale", 100) / 100, 0.01, 10),
                                          depth: clamp(f(p, "textureDepth", 100) / 100, -10, 10), invert: b(p, "textureInvert", false),
                                          link: b(p, "textureLink", true), phase: .zero)
            }
            fx = .bevelEmboss(bv)
        }
    }

    /// photocraft `effect_from_params`: an effect of `kind` from JSON params (Photoshop units:
    /// opacity, spread, range in percent; sizes in px; angles in degrees).
    static func effectFromParams(_ kind: String, _ p: JSONValue) -> Effect? {
        guard var fx = freshEffect(kind) else { return nil }
        overlayEffect(&fx, p)
        return fx
    }

    /// photocraft `kind_of`: the effect's kind as the commands and dialog name it.
    static func kindOf(_ e: Effect) -> String {
        switch e {
        case .dropShadow: "dropShadow"
        case .innerShadow: "innerShadow"
        case .outerGlow: "outerGlow"
        case .innerGlow: "innerGlow"
        case .stroke: "stroke"
        case .colorOverlay: "colorOverlay"
        case .gradientOverlay: "gradientOverlay"
        case .patternOverlay: "patternOverlay"
        case .satin: "satin"
        case .bevelEmboss: "bevelEmboss"
        }
    }

    static func sameKind(_ a: Effect, _ b: Effect) -> Bool { kindOf(a) == kindOf(b) }

    /// Upper bound on the effects one `layer.layerStyle.replace` call accepts, so an automation
    /// mistake can't ask for an unbounded document change.
    static let maxEffects = 256

    // MARK: Commands

    /// The `"layer"` param (a whole number), else the active layer.
    static func targetLayer(_ s: Session, _ p: JSONValue) throws -> LayerId {
        if let id = Params.layerId(p) { return id }
        guard let id = s.active?.activeLayer else { throw EngineError.other("no active layer") }
        return id
    }

    /// Replaces a layer's whole effect list in one history step: the Layer Style dialog's apply.
    /// Each entry builds an effect from `params`, or edits the snapshot it carried (`fx`: the
    /// effect JSON as the dialog loaded it, kept verbatim for everything the dialog doesn't model)
    /// with the params present. Unknown kinds, kind/snapshot mismatches and malformed snapshots
    /// are errors.
    static func replaceEffects(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "layer.layerStyle.replace"
        let id = try targetLayer(s, p)
        guard let entries = p["effects"]?.arrayValue else { throw EngineError.bad(cmd, "need `effects`: [{kind, params, fx?}]") }
        if entries.count > maxEffects { throw EngineError.bad(cmd, "at most \(maxEffects) effects") }
        var list: [Effect] = []
        var pats: [Pattern] = []
        for e in entries {
            guard let kind = e["kind"]?.stringValue else { throw EngineError.bad(cmd, "each effect needs a `kind` string") }
            let params: JSONValue
            switch e["params"] {
            case nil, .null?: params = .object([:])
            case .object(let o)?: params = .object(o)
            default: throw EngineError.bad(cmd, "`params` must be an object")
            }
            var fx: Effect
            if let snapshot = e["fx"] {
                do { fx = try snapshot.decode(as: Effect.self) } catch { throw EngineError.bad(cmd, "bad effect snapshot: \(error)") }
                if kindOf(fx) != kind { throw EngineError.bad(cmd, "effect snapshot is a \(kindOf(fx)), not `\(kind)`") }
                overlayEffect(&fx, params)
            } else {
                guard let built = effectFromParams(kind, params) else { throw EngineError.bad(cmd, "unknown effect \(kind)") }
                fx = built
            }
            let (resolved, pat) = try PatternCommands.resolveEffect(s, fx)
            if let pat { pats.append(pat) }
            list.append(resolved)
        }
        let count = list.count
        let label = list.isEmpty ? "Clear Layer Style" : "Edit Layer Style"
        try s.edit(label) { doc, _ in
            for pat in pats { PatternCommands.ensureInDoc(&doc, pat) }
            let mode = doc.mode
            guard doc.layer(id) != nil else { throw EngineError.noLayer(id) }
            doc.updateLayer(id) { l in
                l.effects.items = list.map { $0.inMode(mode) }
                l.effects.enabled = true
            }
        }
        return ["layer": .id(id), "effects": .int(count)]
    }

    static func setEffect(_ s: Session, _ p: JSONValue, _ kind: String) throws -> JSONValue {
        guard let built = effectFromParams(kind, p) else { throw EngineError.other("unknown effect \(kind)") }
        let (fx0, pattern) = try PatternCommands.resolveEffect(s, built)
        let label = "Layer Style: \(fx0.label)"
        let add = b(p, "add", false)
        let id = try targetLayer(s, p)
        try s.edit(label) { doc, _ in
            if let pattern { PatternCommands.ensureInDoc(&doc, pattern) }
            // Colours in the document's mode, as Image › Mode keeps them.
            let fx = fx0.inMode(doc.mode)
            guard doc.layer(id) != nil else { throw EngineError.noLayer(id) }
            doc.updateLayer(id) { l in
                l.effects.enabled = true
                if !add, let i = l.effects.items.firstIndex(where: { sameKind($0, fx) }) {
                    l.effects.items[i] = fx
                } else {
                    l.effects.items.append(fx)
                }
            }
        }
        return ["layer": .id(id)]
    }

    /// Stores the user default for one effect kind ("Make Default" in the Layer Style dialog).
    static func makeDefault(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "layer.layerStyle.makeDefault"
        let kind = try requiredKind(p, cmd)
        guard case .object(let params)? = p["params"] else { throw EngineError.bad(cmd, "`params` must be an object") }
        s.state[PresetCommands.Key.self].layerDefaults[kind] = .object(params)
        PresetCommands.presetsChanged(s)
        return ["kind": .string(kind)]
    }

    /// The user default for one effect kind, else its factory defaults.
    static func defaultFor(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let kind = try requiredKind(p, "layer.layerStyle.defaultFor")
        if let v = s.state[PresetCommands.Key.self].layerDefaults[kind], v.objectValue != nil {
            return ["params": v, "user": true]
        }
        return ["params": effectDefaults(kind), "user": false]
    }

    static func requiredKind(_ p: JSONValue, _ cmd: String) throws -> String {
        guard let kind = p["kind"]?.stringValue else { throw EngineError.bad(cmd, "need `kind`") }
        if effectFromParams(kind, .null) == nil { throw EngineError.bad(cmd, "unknown effect \(kind)") }
        return kind
    }

    /// photocraft `extra_cmds::style_targets`: the `layer` param or the selected layers; with
    /// several selected, those that can take the change (not the Background, `fits`).
    static func styleTargets(_ s: Session, _ p: JSONValue, _ fits: (Layer) -> Bool) throws -> [LayerId] {
        let ids = try LayerMulti.targets(s, p)
        if ids.count < 2 { return ids }
        guard let d = s.active else { throw EngineError.noDocument }
        let ok = ids.filter { id in d.doc.layer(id).map { !d.doc.isBackground($0.id) && fits($0) } ?? false }
        if ok.isEmpty { throw EngineError.other("none of the selected layers can take this layer style change") }
        return ok
    }

    static func clear(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        if let effect = p["effect"], effect != .null { return try deleteEffect(s, p, effect) }
        let ids = try styleTargets(s, p) { !$0.effects.items.isEmpty }
        try s.edit("Clear Layer Style") { doc, _ in
            for id in ids {
                guard doc.layer(id) != nil else { throw EngineError.noLayer(id) }
                doc.updateLayer(id) { $0.effects = Effects(enabled: true) }
            }
        }
        return .null
    }

    /// `layer.layerStyle.clear` with an `effect` index: deletes that one effect of `layer` (the
    /// active layer without one), as Photoshop does for an effect row dropped on the Delete button.
    static func deleteEffect(_ s: Session, _ p: JSONValue, _ effect: JSONValue) throws -> JSONValue {
        let cmd = "layer.layerStyle.clear"
        guard let raw = effect.uint64Value, let index = Int(exactly: raw) else { throw EngineError.bad(cmd, "`effect` must be an effect index") }
        guard let d = s.active else { throw EngineError.noDocument }
        let id: LayerId
        if let v = p["layer"], v != .null {
            guard let n = v.uint64Value else { throw EngineError.bad(cmd, "`layer` must be a layer id") }
            id = LayerId(n)
        } else {
            guard let a = d.activeLayer else { throw EngineError.bad(cmd, "no active layer") }
            id = a
        }
        guard let count = d.doc.layer(id)?.effects.items.count else { throw EngineError.noLayer(id) }
        if index >= count { throw EngineError.bad(cmd, "the layer has \(count) effect(s), no effect \(index)") }
        try s.edit("Delete Effect") { doc, _ in
            guard doc.layer(id) != nil else { throw EngineError.noLayer(id) }
            doc.updateLayer(id) { l in
                if index < l.effects.items.count { l.effects.items.remove(at: index) }
            }
        }
        return .null
    }

    // MARK: Specs

    static func styleCommand(_ kind: String, _ label: String, _ params: String) -> CommandSpec {
        CommandSpec("layer.layerStyle.\(kind)", label, menu: ["Layer", "Layer Style"], params: params, module: m, enabled: Pre.hasLayer) { s, p in
            try setEffect(s, p, kind)
        }
    }

    static func specs() -> [CommandSpec] {
        [
            styleCommand("dropShadow", "Drop Shadow…",
                         ##"{"color":"#rrggbb","opacity":0..100=75,"blend":str="multiply","angle":deg=120,"useGlobalLight":bool,"distance":px=5,"spread":0..100,"size":px=5,"contour":"Linear|Cone|Cone - Inverted|Cove - Deep|Cove - Shallow|Gaussian|Half Round|Ring|Ring - Double|Rolling Slope - Descending|Rounded Steps|Sawtooth 1"|{"name":str,"points":[[in 0..1,out 0..1],…],"corners":[bool,…]}="Linear","antiAlias":bool,"noise":0..100,"knocksOut":bool,"add":bool,"layer":id}"##),
            styleCommand("innerShadow", "Inner Shadow…",
                         ##"{"color":"#rrggbb","opacity":0..100=75,"blend":str,"angle":deg,"distance":px,"choke":0..100,"size":px,"contour":name|curve,"antiAlias":bool,"noise":0..100,"add":bool}"##),
            styleCommand("outerGlow", "Outer Glow…",
                         ##"{"color":"#rrggbb","opacity":0..100=75,"blend":str="screen","technique":"softer|precise","spread":0..100,"size":px,"range":0..100,"contour":name|curve,"antiAlias":bool,"noise":0..100,"add":bool}"##),
            styleCommand("innerGlow", "Inner Glow…",
                         ##"{"color":"#rrggbb","opacity":0..100=75,"blend":str="screen","technique":"softer|precise","source":"edge|center","choke":0..100,"size":px,"contour":name|curve,"antiAlias":bool,"noise":0..100,"add":bool}"##),
            styleCommand("stroke", "Stroke…",
                         ##"{"size":px=3,"position":"outside|inside|center","color":"#rrggbb","from":"#rrggbb","to":"#rrggbb","style":str,"angle":deg,"opacity":0..100,"blend":str,"add":bool}"##),
            styleCommand("colorOverlay", "Color Overlay…", ##"{"color":"#rrggbb","opacity":0..100=100,"blend":str,"add":bool}"##),
            styleCommand("gradientOverlay", "Gradient Overlay…",
                         ##"{"from":"#rrggbb","to":"#rrggbb","style":"linear|radial|angle|reflected|diamond","angle":deg=90,"scale":10..150=100,"reverse":bool,"opacity":0..100,"blend":str,"add":bool}"##),
            styleCommand("patternOverlay", "Pattern Overlay…",
                         ##"{"pattern":id|name?=first library pattern,"opacity":0..100=100,"blend":str,"scale":1..1000=100,"angle":deg=0,"link":bool=true,"phaseX":px,"phaseY":px,"add":bool}"##),
            styleCommand("bevelEmboss", "Bevel & Emboss…",
                         ##"{"style":"inner|outer|emboss|pillow|stroke","technique":"smooth|chiselHard|chiselSoft","contour":bool,"contourName":name|curve,"contourRange":1..100=50,"contourAntiAlias":bool,"glossContour":name|curve,"texture":pattern id|name?,"textureScale":1..1000=100,"textureDepth":-1000..1000=100,"textureInvert":bool,"textureLink":bool=true,"depth":1..1000=100,"direction":"up|down","size":px=5,"soften":px,"angle":deg,"altitude":deg,"add":bool}"##),
            styleCommand("satin", "Satin…",
                         ##"{"color":"#rrggbb","opacity":0..100=50,"blend":str,"angle":deg,"distance":px,"size":px,"contour":name|curve,"antiAlias":bool=true,"invert":bool,"add":bool}"##),
            CommandSpec("layer.layerStyle.replace", "Edit Layer Style",
                        params: ##"{"layer":id,"effects":[{"kind":"dropShadow|innerShadow|outerGlow|innerGlow|stroke|colorOverlay|gradientOverlay|patternOverlay|satin|bevelEmboss","params":{…layer.layerStyle.<kind> params…},"fx":<effect snapshot carried through the Layer Style dialog, optional>}]} (replaces the layer's whole effect list; an entry with `fx` edits that effect with the params present, one without builds from params)"##,
                        module: m, enabled: Pre.hasLayer, run: replaceEffects),
            CommandSpec("layer.layerStyle.makeDefault", "Make Layer Style Default",
                        params: ##"{"kind":"stroke|dropShadow|innerShadow|outerGlow|innerGlow|colorOverlay|gradientOverlay|patternOverlay|satin|bevelEmboss","params":{…param set…}} (stores the user default the Layer Style dialog's Reset to Default restores)"##,
                        module: m, journal: false, run: makeDefault),
            CommandSpec("layer.layerStyle.defaultFor", "Layer Style Default",
                        params: ##"{"kind":str} → {"params":{…},"user":bool} (the saved user default, else the factory defaults)"##,
                        module: m, journal: false, run: defaultFor),
            CommandSpec("layer.layerStyle.clear", "Clear Layer Style", menu: ["Layer", "Layer Style"],
                        params: ##"{"layer":id? (no layer: every selected layer that has a style),"effect":index? (only that effect of "layer", as an effect row dropped on the Layers panel's Delete button)}"##,
                        module: m, enabled: Pre.hasLayer, run: clear),
        ]
    }
}
