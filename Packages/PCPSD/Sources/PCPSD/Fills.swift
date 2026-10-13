// Descriptor colours and the fill layer blocks: `SoCo` (solid colour), `GdFl` (gradient), `PtFl`
// (pattern).
// Format knowledge ported from photocraft-io (crates/io/src/blocks.rs: color_from_desc,
// color_to_desc, parse_fill, gradient stops), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft
// contributors. The blocks themselves are a version (16) + descriptor per Adobe's specification.

import Foundation

/// A colour as Photoshop stores it in descriptors (`Clr ` values).
public enum PSDColor: Equatable, Sendable {
    /// Components 0...1 (stored as 0...255 doubles in `RGBC`, or `redFloat`… 0...1).
    case rgb(red: Double, green: Double, blue: Double)
    /// Hue in degrees, saturation and brightness 0...1.
    case hsb(hue: Double, saturation: Double, brightness: Double)
    /// Ink amounts 0...1.
    case cmyk(cyan: Double, magenta: Double, yellow: Double, black: Double)
    /// L 0...100, a and b −128...127.
    case lab(l: Double, a: Double, b: Double)
    /// 0 white ... 1 black (Photoshop's `Gry` is ink percent).
    case gray(Double)
    /// A colour-book colour, kept as its descriptor.
    case book(PSDDescriptor)

    public init?(descriptor d: PSDDescriptor) {
        switch d.classID.name {
        case "RGBC":
            if let r = d.number("redFloat"), let g = d.number("greenFloat"), let b = d.number("blueFloat") {
                self = .rgb(red: r, green: g, blue: b)
            } else if let r = d.number("Rd  "), let g = d.number("Grn "), let b = d.number("Bl  ") {
                self = .rgb(red: r / 255, green: g / 255, blue: b / 255)
            } else {
                return nil
            }
        case "HSBC":
            guard let h = d.number("H   "), let s = d.number("Strt"), let b = d.number("Brgh") else { return nil }
            self = .hsb(hue: h, saturation: s / 100, brightness: b / 100)
        case "CMYC":
            guard let c = d.number("Cyn "), let m = d.number("Mgnt"), let y = d.number("Ylw "), let k = d.number("Blck") else { return nil }
            self = .cmyk(cyan: c / 100, magenta: m / 100, yellow: y / 100, black: k / 100)
        case "LbCl":
            guard let l = d.number("Lmnc"), let a = d.number("A   "), let b = d.number("B   ") else { return nil }
            self = .lab(l: l, a: a, b: b)
        case "Grsc":
            guard let g = d.number("Gry ") else { return nil }
            self = .gray(g / 100)
        case "BkCl":
            self = .book(d)
        default:
            return nil
        }
    }

    /// The descriptor Photoshop writes for the colour.
    public var descriptor: PSDDescriptor {
        switch self {
        case let .rgb(r, g, b):
            PSDDescriptor(classID: "RGBC").with("Rd  ", .double(r * 255)).with("Grn ", .double(g * 255)).with("Bl  ", .double(b * 255))
        case let .hsb(h, s, b):
            PSDDescriptor(classID: "HSBC").with("H   ", .unitFloat(unit: "#Ang", value: h)).with("Strt", .double(s * 100)).with("Brgh", .double(b * 100))
        case let .cmyk(c, m, y, k):
            PSDDescriptor(classID: "CMYC").with("Cyn ", .double(c * 100)).with("Mgnt", .double(m * 100)).with("Ylw ", .double(y * 100)).with("Blck", .double(k * 100))
        case let .lab(l, a, b):
            PSDDescriptor(classID: "LbCl").with("Lmnc", .double(l)).with("A   ", .double(a)).with("B   ", .double(b))
        case let .gray(g):
            PSDDescriptor(classID: "Grsc").with("Gry ", .double(g * 100))
        case let .book(d):
            d
        }
    }

    /// Uncolour-managed sRGB approximation (previews).
    public var approximateRGB: (Double, Double, Double)? {
        switch self {
        case let .rgb(r, g, b): return (r, g, b)
        case let .gray(g): return (1 - g, 1 - g, 1 - g)
        case let .cmyk(c, m, y, k): return ((1 - c) * (1 - k), (1 - m) * (1 - k), (1 - y) * (1 - k))
        case let .lab(l, a, b): return LabColor.toSRGB(l: l, a: a, b: b)
        case let .hsb(h, s, v):
            let hh = (h.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
            let c = v * s, x = c * (1 - abs(hh.truncatingRemainder(dividingBy: 2) - 1)), m = v - c
            let (r, g, b): (Double, Double, Double) = switch Int(hh) {
            case 0: (c, x, 0)
            case 1: (x, c, 0)
            case 2: (0, c, x)
            case 3: (0, x, c)
            case 4: (x, 0, c)
            default: (c, 0, x)
            }
            return (r + m, g + m, b + m)
        case .book: return nil
        }
    }
}

/// A gradient as stored in `GdFl`, gradient overlays and gradient maps' descriptors (`Grad`).
public struct PSDGradient: Equatable, Sendable {
    public struct ColorStop: Equatable, Sendable {
        /// 0...1 (stored as 0...4096).
        public var location: Double
        /// Midpoint to the next stop, 0...1 (stored as percent).
        public var midpoint: Double
        public var color: PSDColor?
        /// `UsrS` (user colour), `FrgC` / `BckC` (foreground/background).
        public var type: String
    }

    public struct OpacityStop: Equatable, Sendable {
        public var location: Double
        public var midpoint: Double
        /// 0...1.
        public var opacity: Double
    }

    public var name: String
    /// `CstS` custom stops or `ClNs` noise.
    public var form: String
    /// Smoothness 0...1 (`Intr`, stored 0...4096).
    public var smoothness: Double
    public var colorStops: [ColorStop]
    public var opacityStops: [OpacityStop]

    public init?(descriptor d: PSDDescriptor) {
        name = d.text("Nm  ") ?? ""
        form = d.enumValue("GrdF") ?? "CstS"
        smoothness = (d.number("Intr") ?? 4096) / 4096
        colorStops = (d.list("Clrs") ?? []).compactMap { v in
            guard let s = v.descriptor else { return nil }
            return ColorStop(location: (s.number("Lctn") ?? 0) / 4096, midpoint: (s.number("Mdpn") ?? 50) / 100,
                             color: s.descriptor("Clr ").flatMap(PSDColor.init(descriptor:)), type: s.enumValue("Type") ?? "UsrS")
        }
        opacityStops = (d.list("Trns") ?? []).compactMap { v in
            guard let s = v.descriptor else { return nil }
            return OpacityStop(location: (s.number("Lctn") ?? 0) / 4096, midpoint: (s.number("Mdpn") ?? 50) / 100, opacity: (s.number("Opct") ?? 100) / 100)
        }
        if form == "CstS", colorStops.isEmpty { return nil }
    }
}

/// `SoCo`, `GdFl` or `PtFl`: u32 descriptor version (16) + descriptor.
public struct PSDFillSetting: Equatable, Sendable {
    public var key: FourCC
    public var descriptor: PSDVersionedDescriptor
    /// Padding after the descriptor, kept.
    public var tail: Data

    public init(key: FourCC, descriptor: PSDDescriptor) {
        self.key = key
        self.descriptor = PSDVersionedDescriptor(descriptor)
        tail = Data()
    }

    public init(key: FourCC, bytes: Data) throws {
        self.key = key
        (descriptor, tail) = try bytes.withByteReader { r in (try PSDVersionedDescriptor.read(&r), try r.data(r.remaining)) }
    }

    public func serialized() -> Data {
        var d = descriptor.serialized()
        d.append(tail)
        return d
    }

    /// `SoCo` colour.
    public var solidColor: PSDColor? { descriptor.descriptor.descriptor("Clr ").flatMap(PSDColor.init(descriptor:)) }
    /// `GdFl` gradient.
    public var gradient: PSDGradient? { descriptor.descriptor.descriptor("Grad").flatMap(PSDGradient.init(descriptor:)) }
    /// `GdFl` style (`Lnr `, `Rdl `, `Angl`, `Rflc`, `Dmnd`).
    public var gradientType: String? { descriptor.descriptor.enumValue("Type") }
    /// `GdFl` / `PtFl` angle in degrees.
    public var angle: Double? { descriptor.descriptor.number("Angl") }
    /// `GdFl` / `PtFl` scale in percent.
    public var scale: Double? { descriptor.descriptor.number("Scl ") }
    /// `PtFl` pattern name and id (`Ptrn` descriptor).
    public var pattern: (name: String, id: String)? {
        guard let p = descriptor.descriptor.descriptor("Ptrn") else { return nil }
        return (p.text("Nm  ") ?? "", p.text("Idnt") ?? "")
    }

    /// A `SoCo` block for `color`.
    public static func solid(_ color: PSDColor) -> PSDTaggedBlock {
        PSDTaggedBlock.fourAligned(key: "SoCo", data: PSDVersionedDescriptor(PSDDescriptor().with("Clr ", .descriptor(color.descriptor))).serialized())
    }
}
