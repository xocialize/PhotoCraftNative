// Image › Analysis data stored with a document (measurement scale, count groups, the ruler line)
// and annotations (Notes). Pure data; the measuring itself lives in the engine.
// Port of photocraft-doc (crates/doc/src/analysis.rs), MIT OR Apache-2.0, © ArtCraft Team and the
// PhotoCraft contributors.

import Foundation
import PCFoundation

/// Image › Analysis › Set Measurement Scale: `pixelLength` pixels equal `logicalLength` `units`.
/// The default is 1 pixel = 1 pixel. Every JSON key is optional.
public struct MeasurementScale: Hashable, Sendable, Codable {
    public var pixelLength: Double = 1
    public var logicalLength: Double = 1
    public var units: String = "pixels"

    public init(pixelLength: Double = 1, logicalLength: Double = 1, units: String = "pixels") {
        self.pixelLength = pixelLength; self.logicalLength = logicalLength; self.units = units
    }

    /// Logical units per pixel.
    public var factor: Double { pixelLength > 0 ? logicalLength / pixelLength : 1 }
    public var isDefault: Bool { self == MeasurementScale() }

    /// Photoshop's "Scale" column text, e.g. `1 pixels = 1.0000 pixels`.
    public var describe: String {
        "\(MeasurementScale.trim(pixelLength)) pixels = \(String(format: "%.4f", logicalLength)) \(units)"
    }

    static func trim(_ v: Double) -> String {
        if v.truncatingRemainder(dividingBy: 1) == 0, abs(v) < 9.2e18 { return String(Int64(v)) }
        return rustFloatString(v)
    }

    enum CodingKeys: String, CodingKey { case pixelLength = "pixel_length", logicalLength = "logical_length", units }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = MeasurementScale()
        pixelLength = try c.decode(.pixelLength, or: d.pixelLength)
        logicalLength = try c.decode(.logicalLength, or: d.logicalLength)
        units = try c.decode(.units, or: d.units)
    }
}

/// Rust's `{}` Display of an f64: shortest round-trip digits, no exponent.
func rustFloatString(_ v: Double) -> String {
    if !v.isFinite { return v.isNaN ? "NaN" : (v > 0 ? "inf" : "-inf") }
    let s = "\(v)"
    guard let e = s.firstIndex(where: { $0 == "e" || $0 == "E" }) else { return s }
    // Expand Swift's exponent form to plain digits, as Rust prints.
    let mantissa = String(s[..<e]), exp = Int(s[s.index(after: e)...]) ?? 0
    let negative = mantissa.hasPrefix("-")
    let digits = mantissa.replacingOccurrences(of: "-", with: "")
    let parts = digits.split(separator: ".", omittingEmptySubsequences: false)
    let intPart = String(parts[0]), frac = parts.count > 1 ? String(parts[1]) : ""
    var all = intPart + frac
    var point = intPart.count + exp
    if point <= 0 { all = String(repeating: "0", count: 1 - point) + all; point = 1 }
    if point > all.count { all += String(repeating: "0", count: point - all.count) }
    var out = String(all.prefix(point))
    let rest = String(all.dropFirst(point)).replacingOccurrences(of: "0+$", with: "", options: .regularExpression)
    if !rest.isEmpty { out += "." + rest }
    return (negative ? "-" : "") + out
}

/// One Count tool group: its numbered markers (document pixel coordinates, in click order).
/// Every JSON key is optional.
public struct CountGroup: Hashable, Sendable, Codable {
    public var name: String = "Count Group 1"
    public var color: PCColor = .rgb(1, 0, 0)
    /// Marker (dot) size and label font size, in screen pixels (Photoshop: 1–10 and 8–72).
    public var markerSize: UInt32 = 1
    public var labelSize: UInt32 = 8
    public var visible = true
    public var points: [SIMD2<Double>] = []

    public init(name: String = "Count Group 1", color: PCColor = .rgb(1, 0, 0), markerSize: UInt32 = 1, labelSize: UInt32 = 8,
                visible: Bool = true, points: [SIMD2<Double>] = []) {
        self.name = name; self.color = color; self.markerSize = markerSize; self.labelSize = labelSize
        self.visible = visible; self.points = points
    }

    enum CodingKeys: String, CodingKey { case name, color, markerSize = "marker_size", labelSize = "label_size", visible, points }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CountGroup()
        name = try c.decode(.name, or: d.name)
        color = try c.decode(.color, or: d.color)
        markerSize = try c.decode(.markerSize, or: d.markerSize)
        labelSize = try c.decode(.labelSize, or: d.labelSize)
        visible = try c.decode(.visible, or: d.visible)
        points = try c.decode(.points, or: d.points)
    }
}

/// The Ruler tool line, optionally with a protractor second arm (⌥-drag from an end point).
/// `start` is the vertex the angle is measured at when there is a protractor.
public struct Ruler: Hashable, Sendable, Codable {
    public var start: SIMD2<Double>
    public var end: SIMD2<Double>
    public var protractor: SIMD2<Double>?

    public init(start: SIMD2<Double>, end: SIMD2<Double>, protractor: SIMD2<Double>? = nil) {
        self.start = start; self.end = end; self.protractor = protractor
    }
}

/// Measurement settings and marks of a document (photocraft `Measurement`; renamed to avoid
/// Foundation's `Measurement`). Every JSON key is optional.
public struct MeasurementSettings: Hashable, Sendable, Codable {
    public var scale = MeasurementScale()
    public var countGroups: [CountGroup] = []
    /// Index into `countGroups` that new markers go to.
    public var activeCountGroup: Int = 0
    public var ruler: Ruler?

    public init(scale: MeasurementScale = .init(), countGroups: [CountGroup] = [], activeCountGroup: Int = 0, ruler: Ruler? = nil) {
        self.scale = scale; self.countGroups = countGroups; self.activeCountGroup = activeCountGroup; self.ruler = ruler
    }

    public var isEmpty: Bool { self == MeasurementSettings() }

    /// Total markers over every group.
    public var countTotal: Int { countGroups.reduce(0) { $0 + $1.points.count } }

    enum CodingKeys: String, CodingKey { case scale, countGroups = "count_groups", activeCountGroup = "active_count_group", ruler }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        scale = try c.decode(.scale, or: MeasurementScale())
        countGroups = try c.decode(.countGroups, or: [])
        activeCountGroup = try c.decode(.activeCountGroup, or: 0)
        ruler = try c.decodeIfPresent(Ruler.self, forKey: .ruler)
    }
}

/// A Note tool annotation (PSD `Anno` text annotation). Every JSON key is optional.
public struct Note: Hashable, Sendable, Codable {
    public var author: String = ""
    /// Photoshop's default note colour (pale yellow).
    public var color: PCColor = .rgb(1, 1, 0.51)
    public var text: String = ""
    /// Icon position (top-left, document pixels).
    public var position: SIMD2<Double> = .zero
    /// Popup rectangle [left, top, right, bottom] (document pixels), as stored in PSD.
    public var popup: SIMD4<Double> = .zero
    /// Popup shown open.
    public var open = false
    /// Modification date as PDF date text (`D:YYYYMMDDhhmmss…`); empty when unknown.
    public var modified: String = ""

    public init(author: String = "", color: PCColor = .rgb(1, 1, 0.51), text: String = "", position: SIMD2<Double> = .zero,
                popup: SIMD4<Double> = .zero, open: Bool = false, modified: String = "") {
        self.author = author; self.color = color; self.text = text; self.position = position
        self.popup = popup; self.open = open; self.modified = modified
    }

    enum CodingKeys: String, CodingKey { case author, color, text, position, popup, open, modified }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Note()
        author = try c.decode(.author, or: d.author)
        color = try c.decode(.color, or: d.color)
        text = try c.decode(.text, or: d.text)
        position = try c.decode(.position, or: d.position)
        popup = try c.decode(.popup, or: d.popup)
        open = try c.decode(.open, or: d.open)
        modified = try c.decode(.modified, or: d.modified)
    }
}
