// Photoshop gradient files (`.grd`, version 5) and contour presets (`.shc`).
// Port of photocraft-psd (crates/psd/src/grd.rs, shc.rs), MIT OR Apache-2.0, © ArtCraft Team and the
// PhotoCraft contributors.
//
// .grd: `8BGR`, u16 version 5, then a versioned descriptor whose `GrdL` list holds `Grdn` objects
// with a `Grad` object (name, `GrdF` form, `Clrs` colour stops, `Trns` transparency stops).
// .shc: `8BFS`, u16 version 1, u32 count; per contour a u32 version (1/2), Unicode name, u16 point
// count, points as (output, input) u16 pairs, version 2 corner flags, then the u32 input range.

import Foundation

public enum PSDGrd {
    public static let maxGradients = 10_000
    public static let maxStops = 1_000

    public enum Color: Equatable, Sendable {
        /// 0...1.
        case rgb(Float, Float, Float)
        /// Hue degrees, saturation and brightness 0...1.
        case hsb(Float, Float, Float)
        /// Ink 0...1.
        case cmyk(Float, Float, Float, Float)
        /// L 0...100, a, b.
        case lab(Float, Float, Float)
        /// Ink 0...1 (0 = white).
        case gray(Float)
        case foreground
        case background
    }

    public struct Stop: Equatable, Sendable {
        public var location: Float
        public var midpoint: Float
        public var color: Color
        public init(location: Float, midpoint: Float, color: Color) {
            self.location = location
            self.midpoint = midpoint
            self.color = color
        }
    }

    public struct Gradient: Equatable, Sendable {
        public var name: String
        /// A noise gradient (`ClNs`): no stops.
        public var noise: Bool
        public var stops: [Stop]
        /// (location, opacity, midpoint), all 0...1.
        public var opacity: [(location: Float, opacity: Float, midpoint: Float)]

        public init(name: String, noise: Bool = false, stops: [Stop] = [], opacity: [(location: Float, opacity: Float, midpoint: Float)] = []) {
            self.name = name
            self.noise = noise
            self.stops = stops
            self.opacity = opacity
        }

        public static func == (a: Gradient, b: Gradient) -> Bool {
            a.name == b.name && a.noise == b.noise && a.stops == b.stops && a.opacity.count == b.opacity.count
                && zip(a.opacity, b.opacity).allSatisfy { $0.location == $1.location && $0.opacity == $1.opacity && $0.midpoint == $1.midpoint }
        }
    }

    /// Every number becomes an f32 through one saturating guard (only NaN has no value).
    static func finite(_ v: Double) -> Float? { v.isNaN ? nil : Float(max(Double(-Float.greatestFiniteMagnitude), min(Double(Float.greatestFiniteMagnitude), v))) }
    static func f(_ d: PSDDescriptor, _ k: String) -> Float { finite(d.number(k) ?? 0) ?? 0 }
    static func clamp01(_ v: Float) -> Float { min(max(v, 0), 1) }
    static func hue(_ h: Float) -> Float { (0 ... 360).contains(h) ? h : (h.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) }

    static func color(_ c: PSDDescriptor) -> Color? {
        switch c.classID.name {
        case "RGBC": .rgb(clamp01(f(c, "Rd  ") / 255), clamp01(f(c, "Grn ") / 255), clamp01(f(c, "Bl  ") / 255))
        case "HSBC": .hsb(hue(f(c, "H   ")), clamp01(f(c, "Strt") / 100), clamp01(f(c, "Brgh") / 100))
        case "CMYC": .cmyk(clamp01(f(c, "Cyn ") / 100), clamp01(f(c, "Mgnt") / 100), clamp01(f(c, "Ylw ") / 100), clamp01(f(c, "Blck") / 100))
        case "LbCl": .lab(min(max(f(c, "Lmnc"), 0), 100), min(max(f(c, "A   "), -128), 127), min(max(f(c, "B   "), -128), 127))
        case "Grsc": .gray(clamp01(f(c, "Gry ") / 100))
        default: nil
        }
    }

    static func location(_ d: PSDDescriptor) -> Float { clamp01(f(d, "Lctn") / 4096) }
    static func midpoint(_ d: PSDDescriptor) -> Float { clamp01(finite((d.number("Mdpn") ?? 50) / 100) ?? 0.5) }

    static func gradient(_ g: PSDDescriptor) -> Gradient {
        var out = Gradient(name: g.text("Nm  ") ?? "", noise: g.enumValue("GrdF") == "ClNs")
        for v in (g.list("Clrs") ?? []).prefix(maxStops) {
            guard let s = v.descriptor else { continue }
            let c: Color? = s.enumValue("Type") == "FrgC" ? .foreground : s.enumValue("Type") == "BckC" ? .background : s.descriptor("Clr ").flatMap(color)
            if let c { out.stops.append(Stop(location: location(s), midpoint: midpoint(s), color: c)) }
        }
        for v in (g.list("Trns") ?? []).prefix(maxStops) {
            guard let s = v.descriptor else { continue }
            out.opacity.append((location(s), clamp01(finite((s.number("Opct") ?? 100) / 100) ?? 1), midpoint(s)))
        }
        return out
    }

    public static func parse(_ data: Data) throws -> [Gradient] {
        let b = [UInt8](data.prefix(6))
        guard b.count >= 4 else { throw PSDError.unexpectedEOF(offset: 0, needed: 4 - b.count) }
        let sig = FourCC(bytes: b.prefix(4))
        guard sig == "8BGR" else { throw PSDError.invalidSignature(expected: "8BGR", found: sig) }
        guard b.count >= 6 else { throw PSDError.unexpectedEOF(offset: 4, needed: 6 - b.count) }
        let version = UInt16(b[4]) << 8 | UInt16(b[5])
        guard version == 5 else { throw PSDError.unsupported("gradient file version \(version) (only version 5, Photoshop 6 and later)") }
        let (vd, _) = try PSDVersionedDescriptor.parsePrefix(data.dropFirst(6))
        let out = (vd.descriptor.list("GrdL") ?? []).prefix(maxGradients).compactMap { $0.descriptor?.descriptor("Grad").map(gradient) }
        guard !out.isEmpty else { throw PSDError.invalid("the gradient file holds no gradients") }
        return out
    }

    /// Writes version 5 (RGB, foreground and background stops).
    public static func write(_ gradients: [Gradient]) -> Data {
        func en(_ t: String, _ v: String) -> PSDDescriptor.Value { .enumerated(type: PSDDescriptor.ID(t), value: PSDDescriptor.ID(v)) }
        let items: [PSDDescriptor.Value] = gradients.map { g in
            let stops: [PSDDescriptor.Value] = g.stops.map { s in
                var d = PSDDescriptor(classID: "Clrt")
                var type = "UsrS"
                switch s.color {
                case .foreground: type = "FrgC"
                case .background: type = "BckC"
                case let .rgb(r, gg, b):
                    d = d.with("Clr ", .descriptor(PSDDescriptor(classID: "RGBC").with("Rd  ", .double(Double(r) * 255)).with("Grn ", .double(Double(gg) * 255)).with("Bl  ", .double(Double(b) * 255))))
                default:
                    d = d.with("Clr ", .descriptor(PSDDescriptor(classID: "RGBC").with("Rd  ", .double(0)).with("Grn ", .double(0)).with("Bl  ", .double(0))))
                }
                return .descriptor(d.with("Type", en("Clry", type)).with("Lctn", .integer(saturatingInt32(Double((s.location * 4096).rounded()))))
                    .with("Mdpn", .integer(saturatingInt32(Double((s.midpoint * 100).rounded())))))
            }
            let trns: [PSDDescriptor.Value] = g.opacity.map { o in
                .descriptor(PSDDescriptor(classID: "TrnS").with("Opct", .unitFloat(unit: "#Prc", value: Double(o.opacity) * 100))
                    .with("Lctn", .integer(saturatingInt32(Double((o.location * 4096).rounded())))).with("Mdpn", .integer(saturatingInt32(Double((o.midpoint * 100).rounded())))))
            }
            let grad = PSDDescriptor(classID: "Grdn").with("Nm  ", .text(.nulTerminated(g.name))).with("GrdF", en("GrdF", g.noise ? "ClNs" : "CstS"))
                .with("Intr", .double(4096)).with("Clrs", .list(stops)).with("Trns", .list(trns))
            return .descriptor(PSDDescriptor(classID: "Grdn").with("Grad", .descriptor(grad)))
        }
        var out = Data("8BGR".utf8)
        out.append(contentsOf: [0, 5])
        out.append(PSDVersionedDescriptor(PSDDescriptor().with("GrdL", .list(items))).serialized())
        return out
    }
}

public enum PSDShc {
    public static let maxContours = 4096
    public static let maxPoints = 256
    public static let maxNameUnits = 1024

    public struct Point: Equatable, Sendable {
        /// 0...255.
        public var input: Float
        public var output: Float
        /// Smooth (`true`) or corner.
        public var continuous: Bool
        public init(input: Float, output: Float, continuous: Bool = true) {
            self.input = input
            self.output = output
            self.continuous = continuous
        }
    }

    public struct Contour: Equatable, Sendable {
        public var name: String
        public var points: [Point]
        public init(name: String, points: [Point]) {
            self.name = name
            self.points = points
        }
    }

    static func readName(_ r: inout ByteReader) throws -> String {
        let n = UInt64(try r.u32())
        try r.checkCount(n, minItemSize: 2)
        var units: [UInt16] = []
        for _ in 0 ..< n {
            let u = try r.u16()
            if units.count < maxNameUnits { units.append(u) }
        }
        // A count that leaves out the terminator: the NUL follows (a point count is never 0).
        if units.last != 0, r.peekU8() == 0, r.peekU8(at: 1) == 0 { _ = try r.u16() }
        while units.last == 0 { units.removeLast() }
        return String(decoding: units, as: UTF16.self)
    }

    public static func parse(_ data: Data) throws -> [Contour] {
        try data.withByteReader { r in
            let sig = try r.fourCC()
            guard sig == "8BFS" else { throw PSDError.invalidSignature(expected: "8BFS", found: sig) }
            let v = try r.u16()
            guard v == 1 else { throw PSDError.unsupportedVersion(v) }
            let count = UInt64(try r.u32())
            try r.checkCount(count, minItemSize: 18)
            guard count <= UInt64(maxContours) else { throw PSDError.limitExceeded("too many contours in an .shc file") }
            var out: [Contour] = []
            for _ in 0 ..< count {
                let cv = try r.u32()
                guard cv == 1 || cv == 2 else { throw PSDError.invalid("unknown contour version \(cv)") }
                let name = try readName(&r)
                let n = Int(try r.u16())
                try r.checkCount(UInt64(n), minItemSize: cv == 2 ? 5 : 4)
                guard n <= maxPoints else { throw PSDError.limitExceeded("too many points in a contour") }
                var pts = try (0 ..< n).map { _ -> Point in
                    let o = min(Float(try r.u16()), 255)
                    return Point(input: min(Float(try r.u16()), 255), output: o)
                }
                if cv == 2 { for i in 0 ..< n { pts[i].continuous = try r.u8() != 0 } }
                try r.skip(8)
                out.append(Contour(name: name, points: pts))
            }
            return out
        }
    }

    /// Writes every contour as version 2 (with corner flags).
    public static func write(_ contours: [Contour]) throws -> Data {
        guard contours.count <= maxContours else { throw PSDError.limitExceeded("too many contours for an .shc file") }
        var w = ByteWriter()
        w.fourCC("8BFS"); w.u16(1); w.u32(UInt32(contours.count))
        for c in contours {
            guard c.points.count <= maxPoints else { throw PSDError.limitExceeded("too many points in a contour") }
            w.u32(2)
            let units = Array(c.name.utf16.prefix(maxNameUnits))
            w.u32(UInt32(units.count + 1))
            for u in units { w.u16(u) }
            w.u16(0)
            w.u16(UInt16(c.points.count))
            func level(_ v: Float) -> UInt16 { v.isFinite ? UInt16(min(max(v.rounded(), 0), 255)) : 0 }
            for p in c.points { w.u16(level(p.output)); w.u16(level(p.input)) }
            for p in c.points { w.u8(p.continuous ? 1 : 0) }
            w.u32(0); w.u32(255)
        }
        return w.data
    }
}
