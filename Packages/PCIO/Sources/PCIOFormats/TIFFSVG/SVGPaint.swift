// SVG colours and paints for the import: CSS colour syntax, `currentColor`, gradients (with
// `href` inheritance) and pattern references, resolved the way usvg hands them to photocraft-io
// (crates/io/src/svg.rs `paint`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft
// contributors.

import CoreGraphics
import Foundation

extension SVGImport {
    /// An sRGB colour with alpha, 0...1.
    struct RGBA: Equatable {
        var r: Double, g: Double, b: Double, a: Double
    }

    /// A gradient stop (offset 0...1, colour with the stop opacity folded into alpha).
    struct Stop {
        var offset: Double
        var color: RGBA
    }

    /// A resolved gradient. Geometry is in gradient space; `transform` maps it to user space
    /// (`gradientTransform` and, for `objectBoundingBox` units, the bounding box folded in).
    struct Gradient {
        var radial: Bool
        var stops: [Stop]
        var transform: CGAffineTransform
        // Linear.
        var x1 = 0.0, y1 = 0.0, x2 = 1.0, y2 = 0.0
        // Radial.
        var cx = 0.5, cy = 0.5, r = 0.5, fx = 0.5, fy = 0.5
    }

    /// A resolved paint.
    enum Paint {
        case color(RGBA)
        case gradient(Gradient)
        case pattern(Node)
    }

    // MARK: Colours

    /// A CSS colour (`#rgb`, `#rgba`, `#rrggbb`, `#rrggbbaa`, `rgb()`, `rgba()`, `hsl()`,
    /// `hsla()`, the named colours, `transparent`); `currentColor` is resolved by the caller.
    static func parseColor(_ s0: String) -> RGBA? {
        let s = s0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.hasPrefix("#") {
            let hex = Array(s.dropFirst())
            guard hex.allSatisfy(\.isHexDigit) else { return nil }
            let v = hex.map { Double(Int(String($0), radix: 16) ?? 0) }
            switch hex.count {
            case 3, 4:
                return RGBA(r: v[0] * 17 / 255, g: v[1] * 17 / 255, b: v[2] * 17 / 255, a: hex.count == 4 ? v[3] * 17 / 255 : 1)
            case 6, 8:
                func pair(_ i: Int) -> Double { (v[i] * 16 + v[i + 1]) / 255 }
                return RGBA(r: pair(0), g: pair(2), b: pair(4), a: hex.count == 8 ? pair(6) : 1)
            default: return nil
            }
        }
        if let open = s.firstIndex(of: "("), s.hasSuffix(")") {
            let fn = s[..<open].trimmingCharacters(in: .whitespaces)
            let inner = s[s.index(after: open) ..< s.index(before: s.endIndex)]
            let parts = inner.replacingOccurrences(of: "/", with: " ").split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init)
            func comp(_ t: String, _ scale: Double) -> Double? {
                if t.hasSuffix("%") { return Double(t.dropLast()).map { $0 / 100 } }
                return Double(t).map { $0 / scale }
            }
            func alpha(_ i: Int) -> Double { i < parts.count ? max(0, min(1, comp(parts[i], 1) ?? 1)) : 1 }
            switch fn {
            case "rgb", "rgba":
                guard parts.count >= 3, let r = comp(parts[0], 255), let g = comp(parts[1], 255), let b = comp(parts[2], 255) else { return nil }
                return RGBA(r: max(0, min(1, r)), g: max(0, min(1, g)), b: max(0, min(1, b)), a: alpha(3))
            case "hsl", "hsla":
                guard parts.count >= 3, let h0 = Double(parts[0].replacingOccurrences(of: "deg", with: "")),
                      let sat = comp(parts[1], 100), let l = comp(parts[2], 100) else { return nil }
                let h = (h0.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 360
                let (sv, lv) = (max(0, min(1, sat)), max(0, min(1, l)))
                let q = lv < 0.5 ? lv * (1 + sv) : lv + sv - lv * sv
                let p = 2 * lv - q
                func hue(_ t0: Double) -> Double {
                    var t = t0
                    if t < 0 { t += 1 }
                    if t > 1 { t -= 1 }
                    if t < 1.0 / 6 { return p + (q - p) * 6 * t }
                    if t < 0.5 { return q }
                    if t < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - t) * 6 }
                    return p
                }
                return RGBA(r: hue(h + 1.0 / 3), g: hue(h), b: hue(h - 1.0 / 3), a: alpha(3))
            default: return nil
            }
        }
        if s == "transparent" { return RGBA(r: 0, g: 0, b: 0, a: 0) }
        guard let v = namedColors[s] else { return nil }
        return RGBA(r: Double(v >> 16) / 255, g: Double(v >> 8 & 0xFF) / 255, b: Double(v & 0xFF) / 255, a: 1)
    }

    /// The `color` property of a computed style (for `currentColor`), black by default.
    static func currentColor(_ style: [String: String]) -> RGBA {
        style["color"].flatMap(parseColor) ?? RGBA(r: 0, g: 0, b: 0, a: 1)
    }

    /// A colour value that may be `currentColor`.
    static func color(_ s: String?, _ style: [String: String]) -> RGBA? {
        guard let s else { return nil }
        if s.trimmingCharacters(in: .whitespaces).lowercased() == "currentcolor" { return currentColor(style) }
        return parseColor(s)
    }

    // MARK: Paints

    /// Resolves `fill` / `stroke`: `nil` for `none`, a missing reference without fallback, or a
    /// gradient that paints nothing. `bbox` is the element's object bounding box (user space).
    static func paint(_ value: String?, _ style: [String: String], _ ids: [String: Node], bbox: CGRect, viewport: CGSize) -> Paint? {
        guard let v = value?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty, v != "none" else { return nil }
        if v.hasPrefix("url(") {
            let fallback = v.firstIndex(of: ")").map { v[v.index(after: $0)...].trimmingCharacters(in: .whitespaces) } ?? ""
            if let id = reference(v), let target = ids[id] {
                switch target.name {
                case "linearGradient", "radialGradient":
                    return gradient(target, ids, bbox: bbox, viewport: viewport)
                case "pattern":
                    return .pattern(target)
                default:
                    break
                }
            }
            if fallback.isEmpty || fallback == "none" { return nil }
            return color(fallback, style).map(Paint.color)
        }
        return color(v, style).map(Paint.color)
    }

    /// A gradient with its `href` chain resolved; a single stop paints that colour, no stops
    /// paint nothing (as usvg).
    static func gradient(_ node: Node, _ ids: [String: Node], bbox: CGRect, viewport: CGSize) -> Paint? {
        // The chain: this gradient, then the ones it references.
        var chain: [Node] = []
        var seen = Set<ObjectIdentifier>()
        var cur: Node? = node
        while let n = cur, ["linearGradient", "radialGradient"].contains(n.name), !seen.contains(ObjectIdentifier(n)), chain.count < 32 {
            chain.append(n)
            seen.insert(ObjectIdentifier(n))
            cur = reference(n.attrs["href"]).flatMap { ids[$0] }
        }
        func attr(_ k: String) -> String? { chain.lazy.compactMap { $0.attrs[k] }.first }
        var stops: [Stop] = []
        if let owner = chain.first(where: { $0.children.contains { $0.name == "stop" } }) {
            var last = 0.0
            for s in owner.children where s.name == "stop" {
                var off = 0.0
                if let o = s.attrs["offset"]?.trimmingCharacters(in: .whitespaces) {
                    off = o.hasSuffix("%") ? (Double(o.dropLast()) ?? 0) / 100 : Double(o) ?? 0
                }
                off = max(last, max(0, min(1, off.isFinite ? off : 0)))
                last = off
                let style = computedStyle([:], s)
                var c = color(style["stop-color"], style) ?? RGBA(r: 0, g: 0, b: 0, a: 1)
                let op = Double(style["stop-opacity"]?.trimmingCharacters(in: .whitespaces) ?? "1") ?? 1
                c.a *= max(0, min(1, op.isFinite ? op : 1))
                stops.append(Stop(offset: off, color: c))
            }
        }
        guard let first = stops.first else { return nil }
        if stops.count == 1 { return .color(first.color) }
        let bboxUnits = (attr("gradientUnits") ?? "objectBoundingBox") != "userSpaceOnUse"
        if bboxUnits, bbox.width <= 0 || bbox.height <= 0 { return nil }
        var g = Gradient(radial: node.name == "radialGradient", stops: stops, transform: parseTransform(attr("gradientTransform")))
        let w = bboxUnits ? 1 : viewport.width, h = bboxUnits ? 1 : viewport.height
        let diag = bboxUnits ? 1 : ((w * w + h * h) / 2).squareRoot()
        func coord(_ k: String, _ base: Double, _ def: String) -> Double {
            let s = attr(k) ?? def
            if bboxUnits, !s.hasSuffix("%") { return Double(s.trimmingCharacters(in: .whitespaces)) ?? length(def, percentBase: base) ?? 0 }
            return length(s, percentBase: base) ?? length(def, percentBase: base) ?? 0
        }
        if g.radial {
            g.cx = coord("cx", w, "50%")
            g.cy = coord("cy", h, "50%")
            g.r = coord("r", diag, "50%")
            g.fx = attr("fx") != nil ? coord("fx", w, "50%") : g.cx
            g.fy = attr("fy") != nil ? coord("fy", h, "50%") : g.cy
            // A zero radius paints the last stop's colour.
            if !(g.r > 0) { return stops.last.map { .color($0.color) } }
        } else {
            g.x1 = coord("x1", w, "0%")
            g.y1 = coord("y1", h, "0%")
            g.x2 = coord("x2", w, "100%")
            g.y2 = coord("y2", h, "0%")
        }
        if bboxUnits {
            let bb = CGAffineTransform(a: bbox.width, b: 0, c: 0, d: bbox.height, tx: bbox.minX, ty: bbox.minY)
            g.transform = then(g.transform, bb)
        }
        guard isFinite(g.transform) else { return nil }
        return .gradient(g)
    }

    /// CSS named colours.
    static let namedColors: [String: UInt32] = [
        "aliceblue": 0xF0F8FF, "antiquewhite": 0xFAEBD7, "aqua": 0x00FFFF, "aquamarine": 0x7FFFD4, "azure": 0xF0FFFF,
        "beige": 0xF5F5DC, "bisque": 0xFFE4C4, "black": 0x000000, "blanchedalmond": 0xFFEBCD, "blue": 0x0000FF,
        "blueviolet": 0x8A2BE2, "brown": 0xA52A2A, "burlywood": 0xDEB887, "cadetblue": 0x5F9EA0, "chartreuse": 0x7FFF00,
        "chocolate": 0xD2691E, "coral": 0xFF7F50, "cornflowerblue": 0x6495ED, "cornsilk": 0xFFF8DC, "crimson": 0xDC143C,
        "cyan": 0x00FFFF, "darkblue": 0x00008B, "darkcyan": 0x008B8B, "darkgoldenrod": 0xB8860B, "darkgray": 0xA9A9A9,
        "darkgreen": 0x006400, "darkgrey": 0xA9A9A9, "darkkhaki": 0xBDB76B, "darkmagenta": 0x8B008B, "darkolivegreen": 0x556B2F,
        "darkorange": 0xFF8C00, "darkorchid": 0x9932CC, "darkred": 0x8B0000, "darksalmon": 0xE9967A, "darkseagreen": 0x8FBC8F,
        "darkslateblue": 0x483D8B, "darkslategray": 0x2F4F4F, "darkslategrey": 0x2F4F4F, "darkturquoise": 0x00CED1,
        "darkviolet": 0x9400D3, "deeppink": 0xFF1493, "deepskyblue": 0x00BFFF, "dimgray": 0x696969, "dimgrey": 0x696969,
        "dodgerblue": 0x1E90FF, "firebrick": 0xB22222, "floralwhite": 0xFFFAF0, "forestgreen": 0x228B22, "fuchsia": 0xFF00FF,
        "gainsboro": 0xDCDCDC, "ghostwhite": 0xF8F8FF, "gold": 0xFFD700, "goldenrod": 0xDAA520, "gray": 0x808080,
        "grey": 0x808080, "green": 0x008000, "greenyellow": 0xADFF2F, "honeydew": 0xF0FFF0, "hotpink": 0xFF69B4,
        "indianred": 0xCD5C5C, "indigo": 0x4B0082, "ivory": 0xFFFFF0, "khaki": 0xF0E68C, "lavender": 0xE6E6FA,
        "lavenderblush": 0xFFF0F5, "lawngreen": 0x7CFC00, "lemonchiffon": 0xFFFACD, "lightblue": 0xADD8E6, "lightcoral": 0xF08080,
        "lightcyan": 0xE0FFFF, "lightgoldenrodyellow": 0xFAFAD2, "lightgray": 0xD3D3D3, "lightgreen": 0x90EE90,
        "lightgrey": 0xD3D3D3, "lightpink": 0xFFB6C1, "lightsalmon": 0xFFA07A, "lightseagreen": 0x20B2AA,
        "lightskyblue": 0x87CEFA, "lightslategray": 0x778899, "lightslategrey": 0x778899, "lightsteelblue": 0xB0C4DE,
        "lightyellow": 0xFFFFE0, "lime": 0x00FF00, "limegreen": 0x32CD32, "linen": 0xFAF0E6, "magenta": 0xFF00FF,
        "maroon": 0x800000, "mediumaquamarine": 0x66CDAA, "mediumblue": 0x0000CD, "mediumorchid": 0xBA55D3,
        "mediumpurple": 0x9370DB, "mediumseagreen": 0x3CB371, "mediumslateblue": 0x7B68EE, "mediumspringgreen": 0x00FA9A,
        "mediumturquoise": 0x48D1CC, "mediumvioletred": 0xC71585, "midnightblue": 0x191970, "mintcream": 0xF5FFFA,
        "mistyrose": 0xFFE4E1, "moccasin": 0xFFE4B5, "navajowhite": 0xFFDEAD, "navy": 0x000080, "oldlace": 0xFDF5E6,
        "olive": 0x808000, "olivedrab": 0x6B8E23, "orange": 0xFFA500, "orangered": 0xFF4500, "orchid": 0xDA70D6,
        "palegoldenrod": 0xEEE8AA, "palegreen": 0x98FB98, "paleturquoise": 0xAFEEEE, "palevioletred": 0xDB7093,
        "papayawhip": 0xFFEFD5, "peachpuff": 0xFFDAB9, "peru": 0xCD853F, "pink": 0xFFC0CB, "plum": 0xDDA0DD,
        "powderblue": 0xB0E0E6, "purple": 0x800080, "rebeccapurple": 0x663399, "red": 0xFF0000, "rosybrown": 0xBC8F8F,
        "royalblue": 0x4169E1, "saddlebrown": 0x8B4513, "salmon": 0xFA8072, "sandybrown": 0xF4A460, "seagreen": 0x2E8B57,
        "seashell": 0xFFF5EE, "sienna": 0xA0522D, "silver": 0xC0C0C0, "skyblue": 0x87CEEB, "slateblue": 0x6A5ACD,
        "slategray": 0x708090, "slategrey": 0x708090, "snow": 0xFFFAFA, "springgreen": 0x00FF7F, "steelblue": 0x4682B4,
        "tan": 0xD2B48C, "teal": 0x008080, "thistle": 0xD8BFD8, "tomato": 0xFF6347, "turquoise": 0x40E0D0,
        "violet": 0xEE82EE, "wheat": 0xF5DEB3, "white": 0xFFFFFF, "whitesmoke": 0xF5F5F5, "yellow": 0xFFFF00,
        "yellowgreen": 0x9ACD32,
    ]
}
