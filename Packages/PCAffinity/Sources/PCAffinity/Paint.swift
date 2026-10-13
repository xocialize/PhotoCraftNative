// Port of photocraft-affinity (crates/affinity/src/paint.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
// Fills, strokes and colours. Two schemas exist: Affinity 1 (`BFil` fill, `PFil` stroke paint,
// `LSty` stroke style) and Affinity 2/3 (`BFFl`, `LIFl` and `LILn` lists with a current index).

import Darwin

extension Affinity {
    /// A colour as stored: RGB and grey values are encoded in the document's RGB space (sRGB unless the
    /// document embeds another profile), CMYK values go through its CMYK profile. Alpha is straight.
    public enum Color: Equatable, Sendable {
        case rgb(r: Double, g: Double, b: Double, a: Double)
        case cmyk(c: Double, m: Double, y: Double, k: Double, a: Double)
        case gray(v: Double, a: Double)
        /// CIE L*a*b* (D50).
        case lab(l: Double, a: Double, b: Double, alpha: Double)

        public var alpha: Double {
            switch self {
            case .rgb(_, _, _, let a), .cmyk(_, _, _, _, let a), .gray(_, let a): a
            case .lab(_, _, _, let alpha): alpha
            }
        }
    }

    public struct Gradient: Equatable, Sendable {
        public enum Kind: Sendable {
            case linear
            /// Elliptical and radial: distance from the centre in unit space.
            case radial
            /// Angle around the centre.
            case conical
        }

        public struct Stop: Equatable, Sendable {
            public var offset: Double
            public var color: Color
            /// Affinity's midpoint bias for the segment from this stop to the next (0.5 = even blend).
            public var bias: Double

            /// Where, between this stop (0) and the next (1), the blend reaches half way: the bias curve
            /// fitted to Affinity's renders is `t^k` (bias ≥ 0.5) or `1-(1-t)^k`, with `k = 1 + 8·|bias-0.5|`.
            public var halfPoint: Double {
                let k = 1 + 8 * abs(bias - 0.5)
                let h = pow(0.5, 1 / k)
                return bias >= 0.5 ? h : 1 - h
            }
        }

        public var kind: Kind
        public var stops: [Stop]
        /// Unit space to document pixels: linear runs from unit (0,0) to (1,0); radial is the unit
        /// circle; conical starts along unit +x and turns towards unit +y.
        public var transform: Affine
    }

    public enum Paint: Equatable, Sendable {
        case none
        case solid(Color)
        case gradient(Gradient)
    }

    public struct Stroke: Equatable, Sendable {
        public enum Cap: Sendable { case butt, round, square }
        public enum Join: Sendable { case miter, round, bevel }
        public enum Align: Sendable { case center, inside, outside }

        public var paint: Paint
        /// Width in document pixels.
        public var width: Double
        public var cap: Cap
        public var join: Join
        public var miterLimit: Double
        public var align: Align
        /// Dash and gap lengths in document pixels, and the phase.
        public var dash: (lengths: [Double], phase: Double)?
        /// Painted below the fill instead of above it.
        public var behind: Bool

        public static func == (a: Stroke, b: Stroke) -> Bool {
            a.paint == b.paint && a.width == b.width && a.cap == b.cap && a.join == b.join && a.miterLimit == b.miterLimit
                && a.align == b.align && a.dash?.lengths == b.dash?.lengths && a.dash?.phase == b.dash?.phase && a.behind == b.behind
        }
    }

    enum PaintReader {
        /// Gradient stops per gradient.
        static let maxStops = 1024
        /// Spot colours refer to their equivalents; a chain longer than this (or one that loops back
        /// to itself, which photocraft would follow until the stack overflows) is not followed.
        static let maxColorDepth = 8

        static func floats(_ v: Value) -> [Double]? {
            switch v {
            case .floats(let f):
                return f
            case .bytes(let b) where b.count % 4 == 0:
                return stride(from: 0, to: b.count, by: 4).map { i in
                    Double(Float(bitPattern: UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24))
                }
            default:
                return nil
            }
        }

        /// A colour object (`RGBA`, `HSLA`, `CMYK`, `GRAY`, `LABA`, `Pant`).
        static func color(_ r: Reader, _ id: ObjID, depth: Int = 0) -> Color? {
            let s = r.s
            guard let cls = s.classTag(id) else { return nil }
            func col() -> [Double]? {
                guard let f = s.field(id, "_col"), let v = floats(f), v.allSatisfy(\.isFinite) else { return nil }
                return v
            }
            switch cls {
            case "RGBA":
                guard let v = col(), v.count >= 4 else { return nil }
                return .rgb(r: v[0], g: v[1], b: v[2], a: Affinity.clamp(v[3], 0, 1))
            case "HSLA":
                guard let v = col(), v.count >= 4 else { return nil }
                let (r2, g, b) = hsl(v[0], v[1], v[2])
                return .rgb(r: r2, g: g, b: b, a: Affinity.clamp(v[3], 0, 1))
            case "CMYK":
                guard let v = col(), v.count >= 5 else { return nil }
                return .cmyk(c: v[0], m: v[1], y: v[2], k: v[3], a: Affinity.clamp(v[4], 0, 1))
            case "GRAY":
                guard let v = col(), v.count >= 2 else { return nil }
                return .gray(v: v[0], a: Affinity.clamp(v[1], 0, 1))
            case "LABA":
                guard let b = s.bytes(id, "_col"), b.count >= 8 else { return nil }
                func u(_ i: Int) -> Double { Double(UInt16(b[2 * i]) | UInt16(b[2 * i + 1]) << 8) / 65535 }
                return .lab(l: 100 * u(0), a: 255 * u(1) - 128, b: 255 * u(2) - 128, alpha: u(3))
            case "Pant":
                r.warn("spot colours (imported as their RGB equivalent)")
                guard depth < maxColorDepth else { return nil }
                return s.obj(id, "srgb").flatMap { color(r, $0, depth: depth + 1) } ?? s.obj(id, "base").flatMap { color(r, $0, depth: depth + 1) }
            case "RegC":
                return .cmyk(c: 1, m: 1, y: 1, k: 1, a: 1)
            default:
                r.warn("colours in an unknown model")
                return nil
            }
        }

        static func hsl(_ h: Double, _ s: Double, _ l: Double) -> (Double, Double, Double) {
            let c = (1 - abs(2 * l - 1)) * s
            let hp = Affinity.remEuclid(h, 1) * 6
            let x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1))
            let rgb: (Double, Double, Double)
            switch Affinity.saturating(hp) as UInt32 {
            case 0: rgb = (c, x, 0)
            case 1: rgb = (x, c, 0)
            case 2: rgb = (0, c, x)
            case 3: rgb = (0, x, c)
            case 4: rgb = (x, 0, c)
            default: rgb = (c, 0, x)
            }
            let m = l - c / 2
            return (rgb.0 + m, rgb.1 + m, rgb.2 + m)
        }

        /// A fill descriptor (`FDsc`) or, in Affinity 1 files, a bare `FilS`; `local` maps the node's
        /// space to document pixels.
        static func descriptor(_ r: Reader, _ id: ObjID, _ local: Affine) -> Paint? {
            let s = r.s
            let fill: ObjID
            let unit: Affine
            if s.isClass(id, "FDsc") {
                unit = s.floats(id, "FDeX", count: 6).map(Affine.fromXfrm) ?? .identity
                guard let f = s.obj(id, "FDeF") else { return nil }
                fill = f
            } else {
                (fill, unit) = (id, .identity)
            }
            guard let cls = s.classTag(fill) else { return nil }
            switch cls {
            case "FilN":
                return Paint.none
            case "FilS":
                guard let c = s.obj(fill, "Colr"), let color = color(r, c) else { return nil }
                return .solid(color)
            case "FilG":
                let kind: Gradient.Kind
                switch s.enumeration(fill, "Type")?.id {
                case 0?, nil: kind = .linear
                case 1?, 2?: kind = .radial
                case 3?: kind = .conical
                default:
                    r.warn("gradients of an unknown kind (imported as linear)")
                    kind = .linear
                }
                guard let grad = s.obj(fill, "Grad") else { return nil }
                let cols = s.objs(grad, "Cols")
                var posn: [[Double]] = []
                if case .array(let a)? = s.field(grad, "Posn") { posn = a.compactMap(floats) }
                var stops: [Gradient.Stop] = []
                for (c, p) in zip(cols, posn).prefix(maxStops) {
                    guard let color = color(r, c) else { return nil }
                    let offset = Affinity.clamp(p.first.flatMap { $0.isFinite ? $0 : nil } ?? 0, 0, 1)
                    let bias = Affinity.clamp((p.count > 1 && p[1].isFinite ? p[1] : nil) ?? 0.5, 0, 1)
                    stops.append(Gradient.Stop(offset: offset, color: color, bias: bias))
                }
                if stops.isEmpty { return Paint.none }
                return .gradient(Gradient(kind: kind, stops: stops, transform: unit.then(local)))
            case "FilB":
                r.warn("bitmap and pattern fills (left empty)")
                return Paint.none
            default:
                r.warn("fills of an unknown kind (left empty)")
                return Paint.none
            }
        }

        static func current(_ r: Reader, _ id: ObjID, _ list: Tag, _ index: Tag) -> ObjID? {
            let items = r.s.objs(id, list)
            let i = r.s.int(id, index).flatMap { Int(exactly: $0) }.flatMap { $0 >= 0 ? $0 : nil } ?? 0
            return items.indices.contains(i) ? items[i] : items.first
        }

        /// The fills of `list` (artboard backgrounds use `BFFl`).
        static func fills(_ r: Reader, _ id: ObjID, _ local: Affine, _ list: Tag) -> [Paint] {
            guard let d = current(r, id, list, "BFCr") ?? r.s.obj(id, "BFil"),
                  let p = descriptor(r, d, local), p != .none
            else { return [] }
            return [p]
        }

        /// A node's fill and stroke. `local` maps the node's space to document pixels.
        static func nodePaint(_ r: Reader, _ id: ObjID, _ local: Affine) -> ([Paint], [Stroke]) {
            let s = r.s
            let fills = fills(r, id, local, "BFFl")
            if s.objs(id, "BFFl").count > 1 || s.objs(id, "LIFl").count > 1 {
                r.warn("several fills or strokes on one object (only the active one is imported)")
            }
            if let o = s.f64(id, "FOpc"), o < 0.999 {
                r.warn("fill opacity (imported at full fill opacity)")
            }
            if s.obj(id, "Trns") != nil {
                r.warn("transparency gradients (imported without them)")
            }
            let pen: ObjID?
            let style: ObjID?
            if s.field(id, "LIFl") != nil {
                (pen, style) = (current(r, id, "LIFl", "LICr"), current(r, id, "LILn", "LICr"))
            } else {
                (pen, style) = (s.obj(id, "PFil"), s.obj(id, "LSty"))
            }
            var behind = false
            if case .array(let a)? = s.field(id, "DrwO"), a.first == .enumeration(id: 1, version: 0) { behind = true }
            guard let pen, let style, let stroke = stroke(r, pen, style, local, behind) else { return (fills, []) }
            return (fills, [stroke])
        }

        static func stroke(_ r: Reader, _ pen: ObjID, _ ldsc: ObjID, _ local: Affine, _ behind: Bool) -> Stroke? {
            let s = r.s
            guard let paint = descriptor(r, pen, local), paint != .none else { return nil }
            let lsty: ObjID
            if s.isClass(ldsc, "LDsc") {
                guard let l = s.obj(ldsc, "LDeL") else { return nil }
                lsty = l
            } else {
                lsty = ldsc
            }
            guard let weight = s.f64(lsty, "Wght"), weight > 0, weight < 1e7 else { return nil }
            // "Scale with object": the weight follows the object's transform; otherwise it is absolute.
            let scales = s.bool(ldsc, "LDSc") ?? true
            let width = scales ? weight * local.scale : weight
            let data = s.bytes(lsty, "Data") ?? []
            var miterLimit = 4.0
            if data.count >= 8 {
                let m = Double(bitPattern: data[0..<8].reversed().reduce(UInt64(0)) { $0 << 8 | UInt64($1) })
                if m.isFinite, m >= 1 { miterLimit = m }
            }
            func byte(_ i: Int) -> UInt8? { data.indices.contains(i) ? data[i] : nil }
            // Cap and join bytes are only partly understood: (0, 0) is butt/miter in every clean sample;
            // (2, 2) ends plain lines square and brush lines round; joins import round, which never
            // looks wrong.
            let cap: Stroke.Cap
            let join: Stroke.Join
            switch (byte(8), byte(9), byte(10)) {
            case (0?, 0?, _): (cap, join) = (.butt, .miter)
            case (0?, _?, _): (cap, join) = (.butt, .round)
            case (2?, 2?, 3?): (cap, join) = (.round, .round)
            case (2?, 2?, _): (cap, join) = (.square, .round)
            default: (cap, join) = (.round, .round)
            }
            let align: Stroke.Align
            switch s.int(ldsc, "LDSa") {
            case 1?: align = .inside
            case 2?: align = .outside
            default: align = .center
            }
            var dash: (lengths: [Double], phase: Double)?
            if case .array(let a)? = s.field(lsty, "Patn"), byte(10) == 2 || !a.isEmpty {
                var v: [Double] = a.compactMap { if case .float(let f) = $0 { f } else { nil } }
                while v.count >= 2, v[v.count - 1] == 0, v[v.count - 2] == 0 { v.removeLast(2) }
                let valid = !v.isEmpty && v.allSatisfy { $0.isFinite && $0 >= 0 } && v.contains { $0 > 0 }
                if valid { dash = (v.map { $0 * width }, (s.f64(lsty, "Phse") ?? 0) * width) }
            }
            if s.obj(lsty, "Brus") != nil || s.obj(ldsc, "LDeP") != nil {
                r.warn("brush and pressure strokes (imported as plain strokes)")
            }
            return Stroke(paint: paint, width: width, cap: cap, join: join, miterLimit: miterLimit, align: align, dash: dash, behind: behind)
        }
    }
}
