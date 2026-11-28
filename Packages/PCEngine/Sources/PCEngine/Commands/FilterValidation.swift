// Port of photocraft-engine (crates/engine/src/filters/validation.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Validates new core-filter invocations (typed, in range, no unknown keys) and the documented
// choices of the extended filters, without changing how old smart-filter records decode
// (`FilterCommands.paramsFor` stays tolerant).

import PCDocument

enum FilterValidation {
    enum Rule {
        case number(Double, Double)
        case unsigned(UInt64)
        case choice(String)
        case bool

        func accepts(_ v: JSONValue) -> Bool {
            switch self {
            case .number(let lo, let hi): v.doubleValue.map { $0.isFinite && $0 >= lo && $0 <= hi } ?? false
            case .unsigned(let hi): v.uint64Value.map { $0 <= hi } ?? false
            case .choice(let choices): v.stringValue.map { s in choices.split(separator: "|").contains { $0 == s } } ?? false
            case .bool: v.boolValue != nil
            }
        }

        var expected: String {
            switch self {
            case .number(let lo, let hi) where lo == -Double.greatestFiniteMagnitude && hi == Double.greatestFiniteMagnitude: "a finite number"
            case .number(let lo, let hi): "a number in \(display(lo))..\(display(hi))"
            case .unsigned(let hi): "an integer in 0..\(hi)"
            case .choice(let choices): "one of \(choices)"
            case .bool: "a boolean"
            }
        }
    }

    /// Rust's `{}` for an f64: whole numbers without a fraction.
    static func display(_ x: Double) -> String {
        if x.isFinite, x == x.rounded(), abs(x) < 1e15 { return String(Int64(x)) }
        return "\(x)"
    }

    static let anyNumber = Rule.number(-Double.greatestFiniteMagnitude, Double.greatestFiniteMagnitude)
    static let u32Seed = Rule.unsigned(UInt64(UInt32.max))

    /// The bounds and choices are the core filters' public dialog-unit contract. Defaults remain in
    /// `paramsFor`; gallery filters are checked in GalleryCommands.
    static func fields(_ id: String) -> [(String, Rule)]? {
        switch id {
        case "filter.blur.gaussianBlur", "filter.other.highPass": [("radius", .number(0.1, 1000))]
        case "filter.blur.boxBlur": [("radius", .number(1, 2000))]
        case "filter.blur.motionBlur": [("angle", .number(-360, 360)), ("distance", .number(1, 2000))]
        case "filter.blur.radialBlur":
            [("amount", .number(1, 100)), ("method", .choice("spin|zoom")), ("quality", .choice("draft|good|best")),
             ("centerX", .number(0, 1)), ("centerY", .number(0, 1))]
        case "filter.blur.surfaceBlur": [("radius", .number(1, 100)), ("threshold", .number(2, 255))]
        case "filter.sharpen.unsharpMask": [("amount", .number(1, 500)), ("radius", .number(0.1, 1000)), ("threshold", .number(0, 255))]
        case "filter.sharpen.smartSharpen": [("amount", .number(1, 500)), ("radius", .number(0.1, 64)), ("reduceNoise", .number(0, 100))]
        case "filter.noise.addNoise":
            [("amount", .number(0.1, 400)), ("distribution", .choice("uniform|gaussian")), ("monochromatic", .bool), ("seed", u32Seed)]
        case "filter.noise.median": [("radius", .number(1, 500))]
        case "filter.noise.dustAndScratches": [("radius", .number(1, 500)), ("threshold", .number(0, 255))]
        case "filter.pixelate.mosaic": [("cellSize", .number(2, 200))]
        case "filter.stylize.emboss": [("angle", .number(-180, 180)), ("height", .number(1, 100)), ("amount", .number(1, 500))]
        case "filter.distort.twirl": [("angle", .number(-999, 999))]
        case "filter.distort.pinch": [("amount", .number(-100, 100))]
        case "filter.distort.spherize": [("amount", .number(-100, 100)), ("mode", .choice("normal|horizontalOnly|verticalOnly"))]
        case "filter.distort.wave":
            [("generators", .number(1, 999)), ("wavelengthMin", .number(1, 998)), ("wavelengthMax", .number(2, 999)),
             ("amplitudeMin", .number(1, 998)), ("amplitudeMax", .number(1, 999)), ("type", .choice("sine|triangle|square")),
             ("undefinedAreas", .choice("wrap|repeat")), ("seed", u32Seed)]
        case "filter.distort.ripple": [("amount", .number(-999, 999)), ("size", .choice("small|medium|large"))]
        case "filter.distort.polarCoordinates": [("mode", .choice("rectangularToPolar|polarToRectangular"))]
        case "filter.other.minimum", "filter.other.maximum": [("radius", .number(0.2, 500)), ("preserve", .choice("squareness|roundness"))]
        case "filter.other.offset":
            // The hint specifies pixels, with no range: keep the existing rounding/saturation.
            [("horizontal", anyNumber), ("vertical", anyNumber), ("undefinedAreas", .choice("wrap|repeat|transparent"))]
        case "filter.blur.blur", "filter.blur.blurMore", "filter.sharpen.sharpen", "filter.sharpen.sharpenMore", "filter.sharpen.sharpenEdges",
             "filter.noise.despeckle", "filter.stylize.findEdges", "filter.stylize.solarize":
            []
        default: nil
        }
    }

    /// Extended filters: only their documented choices are checked for now, since `prepare`
    /// injects extra keys (colours, map documents) and their numeric ranges clamp in `paramsFor`.
    static func choices(_ id: String) -> [(String, String)]? {
        switch id {
        case "filter.pixelate.mezzotint":
            [("type", "fineDots|mediumDots|grainyDots|coarseDots|shortLines|mediumLines|longLines|shortStrokes|mediumStrokes|longStrokes")]
        case "filter.stylize.diffuse": [("mode", "normal|darkenOnly|lightenOnly|anisotropic")]
        case "filter.stylize.extrude": [("type", "blocks|pyramids"), ("depthMode", "random|levelBased")]
        case "filter.stylize.tiles": [("fill", "background|foreground|inverse|unaltered")]
        case "filter.stylize.traceContour": [("edge", "lower|upper")]
        case "filter.stylize.wind": [("method", "wind|blast|stagger"), ("direction", "fromRight|fromLeft")]
        case "filter.distort.displace": [("fit", "stretch|tile"), ("undefinedAreas", "repeat|wrap")]
        case "filter.distort.shear": [("undefinedAreas", "wrap|repeat")]
        case "filter.distort.zigZag": [("style", "pondRipples|outFromCenter|aroundCenter")]
        case "filter.render.lensFlare": [("lens", "zoom|prime35|prime105|moviePrime")]
        case "filter.render.lightingEffects": [("lightType", "spot|point|infinite"), ("texture", "none|red|green|blue|alpha|luminance")]
        case "filter.blur.smartBlur": [("quality", "high|medium|low"), ("mode", "normal|edgeOnly|overlayEdge")]
        case "filter.blur.lensBlur":
            [("shape", "hexagon|triangle|square|pentagon|heptagon|octagon"), ("depthMap", "none|transparency|layerMask"),
             ("distribution", "uniform|gaussian")]
        case "filter.blur.shapeBlur": [("shape", "circle|ring|square|diamond|triangle|hexagon|star|heart|cross")]
        case "filter.other.hsbHsl": [("inputMode", "rgb|hsb|hsl"), ("rowOrder", "hsb|hsl|rgb")]
        case "filter.video.deInterlace": [("eliminate", "oddFields|evenFields"), ("createBy", "interpolation|duplication")]
        default: nil
        }
    }

    /// photocraft `filters::validate_params`: new invocations' fields typed and in range. Runs both
    /// at dispatch (before a floating selection drops) and at the shared runner (direct specs, Last
    /// Filter). Filters outside the core and extended families are unaffected.
    static func validateParams(_ id: String, _ p: JSONValue) throws {
        func bad(_ msg: String) -> EngineError { .bad(id, msg) }
        if let choices = choices(id) {
            for (key, allowed) in choices {
                if let v = p[key], !Rule.choice(allowed).accepts(v) {
                    throw bad("`\(key)` must be \(Rule.choice(allowed).expected)")
                }
            }
            return
        }
        guard let fields = fields(id) else {
            // photocraft: `gallery_cmds::validate_params(id, params)` (the Filter Gallery's choice
            // names).
            try GalleryCommands.validateParams(id, p)
            return
        }
        if p == .null { return }
        guard let o = p.objectValue else { throw bad("params must be a JSON object") }
        // serde_json's map iterates its keys in order.
        for key in o.keys.sorted() {
            guard let value = o[key] else { continue }
            let valid: Bool
            let expected: String
            if let (_, rule) = fields.first(where: { $0.0 == key }) {
                valid = rule.accepts(value)
                expected = rule.expected
            } else {
                switch key {
                case "layer":
                    valid = value.uint64Value != nil
                    expected = "an unsigned layer id"
                case "coalesce":
                    valid = value.stringValue != nil
                    expected = "a string"
                case "preserveTransparency":
                    // Not photocraft's: a pixel layer keeps its alpha, as a transparency-locked one does
                    // (`FilterCommands.apply`).
                    valid = value.boolValue != nil
                    expected = "true or false"
                case "target":
                    let named = value.stringValue.map { ["pixels", "mask", "quickMask"].contains($0) } ?? false
                    let channel = value.objectValue.map { $0.count == 1 && $0["channel"]?.uint64Value != nil } ?? false
                    valid = named || channel
                    expected = #"pixels, mask, quickMask or {"channel":index}"#
                default:
                    throw bad("unknown parameter `\(key)`")
                }
            }
            if !valid { throw bad("`\(key)` must be \(expected)") }
        }
    }

    /// photocraft's dispatch runs `validate_params` before the floating selection drops (jobs.rs
    /// `dispatch`): a `before` hook, installed by FiltersExtCommands ahead of FloatCommands' hook.
    static func installDispatchCheck(into r: inout CommandRegistry) {
        r.hooks.before.append { _, id, p in
            guard id.hasPrefix("filter.") else { return nil }
            try validateParams(id, p)
            return nil
        }
    }
}
