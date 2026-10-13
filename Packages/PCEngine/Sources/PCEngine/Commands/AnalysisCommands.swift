// Port of photocraft-engine (crates/engine/src/analysis_cmds.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Image › Analysis: measurement scale, data points, Record Measurements and the Measurement Log,
// the Ruler tool (with protractor and Straighten Layer), the Count tool and Place Scale Marker.
//
// The scale, count groups and ruler line are document data (`MeasurementSettings`, saved in
// `.pcraft`; the scale also as PSD resource 1074). The Measurement Log and the data point choices
// are session-wide (`Key`), as in Photoshop.
//
// Selection measurements follow Photoshop's definitions: the selection (coverage ≥ 50 %) is split
// into 8-connected features, each recorded with a summary row first. Area is the pixel count,
// perimeter the length of the marching-squares contour through the pixel-centre grid (exact along
// straight edges, √2 per diagonal step), circularity 4π·area/perimeter², gray values the
// luminosity (0.30 R + 0.59 G + 0.11 B) of the composite in the document's value range (0–255 at
// 8 bits, 0–32768 at 16 bits, 0–1 at 32 bits), integrated density area × mean. Lengths and areas
// are scaled by the measurement scale. The feature measurement itself is in
// `AnalysisCommands+Measure.swift`.

import Foundation
import PCDocument
import PCFoundation

enum AnalysisCommands: CommandModule {
    static let name = "analysis_cmds"
    static let m = "analysis_cmds"

    // MARK: State

    /// Data point columns: (key, Photoshop column header).
    static let columns: [(String, String)] = [
        ("label", "Label"),
        ("dateTime", "Date and Time"),
        ("document", "Document"),
        ("source", "Source"),
        ("scale", "Scale"),
        ("scaleUnits", "Scale Units"),
        ("scaleFactor", "Scale Factor"),
        ("count", "Count"),
        ("area", "Area"),
        ("perimeter", "Perimeter"),
        ("circularity", "Circularity"),
        ("height", "Height"),
        ("width", "Width"),
        ("grayMin", "Gray Value (Minimum)"),
        ("grayMax", "Gray Value (Maximum)"),
        ("grayMean", "Gray Value (Mean)"),
        ("grayMedian", "Gray Value (Median)"),
        ("integratedDensity", "Integrated Density"),
        ("histogram", "Histogram"),
        ("length", "Length"),
        ("angle", "Angle"),
    ]

    static let common = ["label", "dateTime", "document", "source", "scale", "scaleUnits", "scaleFactor"]
    static let selectionOnly = ["count", "area", "perimeter", "circularity", "height", "width", "grayMin", "grayMax", "grayMean", "grayMedian",
                                "integratedDensity", "histogram"]
    static let rulerOnly = ["length", "angle"]
    static let countOnly = ["count"]

    /// Data points a measurement source can record.
    static func available(_ source: String) -> [String] {
        switch source {
        case "selection": common + selectionOnly
        case "ruler": common + rulerOnly
        default: common + countOnly
        }
    }

    /// Image › Analysis › Select Data Points: what Record Measurements writes per source.
    struct DataPoints: Equatable, Sendable {
        var selection = AnalysisCommands.available("selection")
        var ruler = AnalysisCommands.available("ruler")
        var count = AnalysisCommands.available("count")

        func of(_ source: String) -> [String] {
            switch source {
            case "selection": selection
            case "ruler": ruler
            default: count
            }
        }

        mutating func set(_ source: String, _ v: [String]) {
            switch source {
            case "selection": selection = v
            case "ruler": ruler = v
            default: count = v
            }
        }

        var json: JSONValue { ["selection": .strings(selection), "ruler": .strings(ruler), "count": .strings(count)] }
    }

    /// One Measurement Log row: data point values by key (see `columns`).
    struct LogRow: Equatable, Sendable {
        var id: UInt64
        var values: [String: JSONValue]
        var json: JSONValue { ["id": .int(id), "values": .object(values)] }
    }

    /// Session-wide analysis state (photocraft `Session::analysis`).
    struct State: Sendable {
        var log: [LogRow] = []
        var nextRow: UInt64 = 0
        /// Counter for "Measurement N" labels.
        var nextMeasurement: UInt64 = 0
        var dataPoints = DataPoints()
    }

    enum Key: StateKey { static let defaultValue = State() }

    // MARK: Helpers

    static let hasDoc: CommandEnabled = { s, _ in s.active == nil ? "no document open" : nil }

    static let hasRuler: CommandEnabled = { s, _ in
        guard let d = s.active else { return "no document open" }
        return d.doc.measurement.ruler == nil ? "no ruler line" : nil
    }

    static let hasLog: CommandEnabled = { s, _ in s.state[Key.self].log.isEmpty ? "the Measurement Log is empty" : nil }

    static func point(_ v: JSONValue?) -> SIMD2<Double>? {
        guard let a = v?.arrayValue, a.count >= 1, let x = a[0].doubleValue, a.count >= 2, let y = a[1].doubleValue else { return nil }
        return SIMD2(x, y)
    }

    static func xy(_ p: JSONValue) -> SIMD2<Double>? {
        guard let x = p["x"]?.doubleValue, let y = p["y"]?.doubleValue else { return nil }
        return SIMD2(x, y)
    }

    static func doc(_ s: Session) throws -> Document {
        guard let d = s.active else { throw EngineError.noDocument }
        return d.doc
    }

    /// Changes the document without a history step (the ruler line: view-like state that is still
    /// saved with the document). A clean document stays clean.
    static func setQuiet(_ s: Session, _ f: (inout Document) -> Void) throws {
        let id = try s.updateActive { st -> DocId in
            f(&st.doc)
            Session.noEditRevision(&st)
            return st.id
        }
        if let st = s.active { s.emit(.documentChanged(id, revision: st.revision, damage: .empty)) }
    }

    /// Runs several commands as one history step labelled `label` (photocraft `compound`). On
    /// failure the document (with its layer targeting and view state, colour samplers included)
    /// goes back as it was and the journal forgets the commands `f` ran, so an action being
    /// recorded doesn't replay an edit that was taken back.
    static func compound<R>(_ s: Session, _ label: String, _ f: (Session) throws -> R) throws -> R {
        guard let st = s.active else { throw EngineError.noDocument }
        let (before, history, prior, view) = (st.doc, st.history, st.layerTarget, st.view)
        let anchor = st.layerAnchor
        let journal = s.journal.count
        let r: Result<R, EngineError>
        do { r = .success(try f(s)) } catch { r = .failure(EngineError.wrap(error)) }
        if case .failure = r, journal <= s.journal.count { s.journal.removeSubrange(journal...) }
        let id = try s.updateActive { st -> DocId in
            st.history = history
            switch r {
            case .success:
                // As in `Session.edit`: undo targets what was selected just before the step (#1356).
                st.history.setCurrentLayers(prior)
                st.history.record(label, before: before, layers: st.layerTarget)
                st.history.trim(st.doc)
                st.coalesce = nil
                st.lastTransaction = TransactionBuilder.transaction(label, from: before, to: st.doc)
            case .failure:
                st.doc = before
                st.view = view
                st.activeLayer = prior.active
                st.selectedLayerIds = prior.selected
                st.layerAnchor = anchor
                st.revision += 1
                st.lastDamage = nil
                st.lastTransaction = nil
            }
            return st.id
        }
        if case .failure = r, let st = s.active {
            s.emit(.documentChanged(id, revision: st.revision, damage: nil))
            s.publish()
        }
        return try r.get()
    }

    /// Current time as ISO 8601 UTC (`2026-10-01T12:34:56Z`), from the session clock.
    static func nowISO(_ date: Date) -> String {
        let t = date.timeIntervalSince1970
        let secs: Int64 = t.isFinite ? Int64(max(min(t.rounded(.down), 9e15), -9e15)) : 0
        let days = secs >= 0 ? secs / 86_400 : -((-secs + 86_399) / 86_400)
        let rem = secs - days * 86_400
        // Civil date from days since 1970-01-01 (Howard Hinnant's algorithm).
        let z = days + 719_468
        let era = z >= 0 ? z / 146_097 : -((-z + 146_096) / 146_097)
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let mo = mp < 10 ? mp + 3 : mp - 9
        let y = yoe + era * 400 + (mo <= 2 ? 1 : 0)
        return String(format: "%04lld-%02lld-%02lldT%02lld:%02lld:%02lldZ", y, mo, d, rem / 3600, rem % 3600 / 60, rem % 60)
    }

    static func round4(_ v: Double) -> Double { (v * 10_000).rounded() / 10_000 }

    /// Rust's `{}` Display of an f64: shortest round-trip digits, never an exponent, no ".0".
    static func display(_ v: Double) -> String {
        if !v.isFinite { return v.isNaN ? "NaN" : (v > 0 ? "inf" : "-inf") }
        if v == v.rounded(), abs(v) < 1e15 { return String(Int64(v)) }
        let s = "\(v)"
        guard let e = s.firstIndex(where: { $0 == "e" || $0 == "E" }) else { return s }
        let mantissa = String(s[..<e]), exp = Int(s[s.index(after: e)...]) ?? 0
        let negative = mantissa.hasPrefix("-")
        let digits = mantissa.replacingOccurrences(of: "-", with: "")
        let parts = digits.split(separator: ".", omittingEmptySubsequences: false)
        let intPart = String(parts[0]), frac = parts.count > 1 ? String(parts[1]) : ""
        var all = intPart + frac
        var pointAt = intPart.count + exp
        if pointAt <= 0 { all = String(repeating: "0", count: 1 - pointAt) + all; pointAt = 1 }
        if pointAt > all.count { all += String(repeating: "0", count: pointAt - all.count) }
        var out = String(all.prefix(pointAt))
        var rest = String(all.dropFirst(pointAt))
        while rest.hasSuffix("0") { rest.removeLast() }
        if !rest.isEmpty { out += "." + rest }
        return (negative ? "-" : "") + out
    }

    /// serde_json's text of an f64 (ryu): whole numbers keep ".0", exponents are `1e16` / `1e-7`.
    static func jsonNumber(_ v: Double) -> String {
        if !v.isFinite { return "null" }
        if v == v.rounded(), abs(v) < 1e16 { return String(Int64(v)) + ".0" }
        let a = abs(v)
        if a >= 1e16 || a < 1e-5 {
            let s = "\(v)"
            guard let e = s.firstIndex(where: { $0 == "e" || $0 == "E" }) else { return s }
            var mantissa = String(s[..<e])
            if mantissa.hasSuffix(".0") { mantissa.removeLast(2) }
            return mantissa + "e" + String(Int(s[s.index(after: e)...]) ?? 0)
        }
        return display(v)
    }

    // MARK: Scale

    static func scaleJSON(_ sc: MeasurementScale) -> JSONValue {
        ["pixelLength": .number(sc.pixelLength), "logicalLength": .number(sc.logicalLength), "units": .string(sc.units),
         "factor": .number(sc.factor), "text": .string(sc.describe), "default": .bool(sc.isDefault)]
    }

    static func setScale(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "image.analysis.setMeasurementScale"
        let cur = try doc(s).measurement.scale
        let preset = p["preset"]?.stringValue ?? ((p.objectValue?.isEmpty ?? true) ? "query" : "custom")
        let next: MeasurementScale
        switch preset {
        case "query": return scaleJSON(cur)
        case "default": next = MeasurementScale()
        case "custom":
            let pl = p["pixelLength"]?.doubleValue ?? cur.pixelLength
            let ll = p["logicalLength"]?.doubleValue ?? cur.logicalLength
            let units = (p["units"] ?? p["logicalUnits"])?.stringValue ?? cur.units
            if !(pl > 0 && pl.isFinite && ll > 0 && ll.isFinite) { throw EngineError.bad(cmd, "pixelLength and logicalLength must be positive") }
            if units.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw EngineError.bad(cmd, "units must not be empty") }
            next = MeasurementScale(pixelLength: pl, logicalLength: ll, units: units)
        default: throw EngineError.bad(cmd, "unknown preset `\(preset)` (default|custom)")
        }
        if next != cur {
            try s.edit("Set Measurement Scale") { d, _ in d.measurement.scale = next }
        }
        return scaleJSON(next)
    }

    // MARK: Data points

    static func columnIndex(_ k: String) -> Int { columns.firstIndex { $0.0 == k } ?? columns.count }

    static func selectDataPoints(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "image.analysis.selectDataPoints"
        var next = p["reset"]?.boolValue == true ? DataPoints() : s.state[Key.self].dataPoints
        for source in ["selection", "ruler", "count"] {
            let avail = available(source)
            guard let v = p[source] else { continue }
            var list = next.of(source)
            switch v {
            // A full list of keys…
            case .array(let a):
                var keys: [String] = []
                for k in a {
                    guard let k = k.stringValue else { throw EngineError.bad(cmd, "`\(source)` entries must be strings") }
                    if !avail.contains(k) { throw EngineError.bad(cmd, "`\(k)` is not a \(source) data point (\(avail.joined(separator: "|")))") }
                    keys.append(k)
                }
                list = keys
            // …or {key: on/off} changes.
            case .object(let o):
                for k in o.keys.sorted() {
                    if !avail.contains(k) { throw EngineError.bad(cmd, "`\(k)` is not a \(source) data point (\(avail.joined(separator: "|")))") }
                    guard let on = o[k]?.boolValue else { throw EngineError.bad(cmd, "`\(source).\(k)` must be a bool") }
                    list.removeAll { $0 == k }
                    if on { list.append(k) }
                }
            default:
                throw EngineError.bad(cmd, "`\(source)` must be a list of keys or an object of bools")
            }
            // Keep the column order (a stable sort, as Rust's `sort_by_key`).
            list = list.enumerated().sorted { (columnIndex($0.element), $0.offset) < (columnIndex($1.element), $1.offset) }.map(\.element)
            next.set(source, list)
        }
        s.state[Key.self].dataPoints = next
        return [
            "dataPoints": next.json,
            "available": ["selection": .strings(available("selection")), "ruler": .strings(available("ruler")), "count": .strings(available("count"))],
            "columns": .array(columns.map { ["key": .string($0.0), "name": .string($0.1)] }),
        ]
    }

    // MARK: Ruler

    /// Ruler readout: X/Y (start), W/H, angle A and lengths L1/L2, as in the options bar.
    static func rulerInfo(_ r: Ruler, _ sc: MeasurementScale) -> JSONValue {
        let (dx, dy) = (r.end.x - r.start.x, r.end.y - r.start.y)
        let l1 = hypot(dx, dy)
        let f = sc.factor
        let deg = 180.0 / Double.pi
        guard let q = r.protractor else {
            // Counter-clockwise from the +x axis with y up, −180…180.
            let a = atan2(-dy, dx) * deg
            return ["x": .number(r.start.x), "y": .number(r.start.y), "w": .number(dx), "h": .number(dy), "angle": .number(round4(a)),
                    "l1": .number(round4(l1)), "l2": .null, "length": .number(round4(l1 * f)), "units": .string(sc.units), "protractor": false]
        }
        let (ex, ey) = (q.x - r.start.x, q.y - r.start.y)
        let l2 = hypot(ex, ey)
        let a1 = atan2(-dy, dx), a2 = atan2(-ey, ex)
        var a = abs((a1 - a2) * deg)
        if a > 180 { a = 360 - a }
        return ["x": .number(r.start.x), "y": .number(r.start.y), "w": .number(dx), "h": .number(dy), "angle": .number(round4(a)),
                "l1": .number(round4(l1)), "l2": .number(round4(l2)), "length": .number(round4(l1 * f)), "units": .string(sc.units), "protractor": true]
    }

    static func pointJSON(_ p: SIMD2<Double>) -> JSONValue { .doubles([p.x, p.y]) }

    static func rulerJSON(_ r: Ruler) -> JSONValue {
        ["start": pointJSON(r.start), "end": pointJSON(r.end), "protractor": r.protractor.map(pointJSON) ?? .null]
    }

    static func rulerTool(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "image.analysis.rulerTool"
        let d = try doc(s)
        if p["clear"]?.boolValue == true {
            try setQuiet(s) { $0.measurement.ruler = nil }
            return ["ruler": .null]
        }
        let start = point(p["start"]), end = point(p["end"])
        var r = d.measurement.ruler
        switch (start, end) {
        case let (a?, b?):
            var prot: SIMD2<Double>?
            if let v = p["protractor"], v != .null {
                guard let q = point(v) else { throw EngineError.bad(cmd, "`protractor` must be [x, y] or null") }
                prot = q
            }
            r = Ruler(start: a, end: b, protractor: prot)
        case (nil, nil):
            if var cur = r, let v = p["protractor"] {
                if v == .null {
                    cur.protractor = nil
                } else {
                    guard let q = point(v) else { throw EngineError.bad(cmd, "`protractor` must be [x, y] or null") }
                    cur.protractor = q
                }
                r = cur
            }
        default:
            throw EngineError.bad(cmd, "pass both `start` and `end`")
        }
        if let r {
            for v in [r.start, r.end] + (r.protractor.map { [$0] } ?? []) where !v.x.isFinite || !v.y.isFinite {
                throw EngineError.bad(cmd, "coordinates must be finite")
            }
        }
        if r != d.measurement.ruler {
            try setQuiet(s) { $0.measurement.ruler = r }
        }
        guard let r else { return ["ruler": .null] }
        return ["ruler": rulerJSON(r), "info": rulerInfo(r, d.measurement.scale)]
    }

    /// Largest axis-aligned rectangle of a `w`×`h` rectangle rotated by `a` radians.
    static func inscribed(_ w: Double, _ h: Double, _ a: Double) -> (Double, Double) {
        let (sa, ca) = (abs(sin(a)), abs(cos(a)))
        let longW = w >= h
        let (long, short) = longW ? (w, h) : (h, w)
        if short <= 2 * sa * ca * long || abs(sa - ca) < 1e-10 {
            let x = 0.5 * short
            return longW ? (x / sa, x / ca) : (x / ca, x / sa)
        }
        let c2 = ca * ca - sa * sa
        return ((w * ca - h * sa) / c2, (h * ca - w * sa) / c2)
    }

    /// Clockwise rotation in degrees that turns the ruler line onto its nearest axis.
    static func straightenAngle(_ r: Ruler) -> Double {
        let (dx, dy) = (r.end.x - r.start.x, r.end.y - r.start.y)
        let a = atan2(-dy, dx) * (180.0 / Double.pi)
        return a - 90 * (a / 90).rounded()
    }

    /// Straighten Layer. Runs `image.rotation.arbitrary` + `image.crop` (the Background) or
    /// `edit.transform` (a layer) as one step.
    static func straighten(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let d = try doc(s)
        guard let r = d.measurement.ruler else { throw EngineError.other("no ruler line") }
        let rot = straightenAngle(r)
        if abs(rot) < 1e-9 { return ["angle": 0.0] }
        guard let st = s.active else { throw EngineError.noDocument }
        let activeBg = st.activeLayer.map { d.layer($0) != nil && d.isBackground($0) } ?? false
        let crop = p["crop"]?.boolValue ?? (activeBg || st.activeLayer == nil)
        let (w0, h0) = (Double(d.size.width), Double(d.size.height))
        let rad = rot * (Double.pi / 180)
        try compound(s, "Straighten") { s in
            if crop {
                try s.execute("image.rotation.arbitrary", ["angle": .number(rot), "direction": "cw"])
                let nd = try doc(s)
                let (cw0, ch0) = inscribed(w0, h0, rad)
                let (nw, nh) = (Double(nd.size.width), Double(nd.size.height))
                let (cw, ch) = (min(max(cw0.rounded(.down), 1), nw), min(max(ch0.rounded(.down), 1), nh))
                try s.execute("image.crop", ["x": .number(((nw - cw) / 2).rounded()), "y": .number(((nh - ch) / 2).rounded()),
                                             "width": .number(cw), "height": .number(ch)])
            } else {
                let (cx, cy) = (w0 / 2, h0 / 2)
                let (sn, cs) = (sin(rad), cos(rad))
                // Clockwise on screen (y down) about the canvas centre.
                let mtx = [cs, sn, -sn, cs, cx - (cs * cx - sn * cy), cy - (sn * cx + cs * cy)]
                try s.execute("edit.transform", ["matrix": .doubles(mtx)])
            }
            // The ruler is cleared after straightening, as in Photoshop.
            try setQuiet(s) { $0.measurement.ruler = nil }
        }
        let nd = try doc(s)
        return ["angle": .number(round4(rot)), "cropped": .bool(crop), "width": .int(nd.size.width), "height": .int(nd.size.height)]
    }

    static let straightenParams = #"{"crop":bool=(active layer is the Background)} (rotates so the ruler line is level; crop = rotate the canvas and crop to the image)"#

    /// Image › Analysis › Straighten Layer (the layer path runs `edit.transform`, transform_cmds).
    static var straightenSpec: CommandSpec {
        CommandSpec("image.analysis.straightenLayer", "Straighten Layer", params: straightenParams, module: m, enabled: hasRuler) { s, p in
            try straighten(s, p)
        }
    }

    // MARK: Count

    static func groupIndex(_ d: Document, _ p: JSONValue) -> Int? {
        let i = p["group"]?.uint64Value.map { Int(clamping: $0) } ?? d.measurement.activeCountGroup
        return i >= 0 && i < d.measurement.countGroups.count ? i : nil
    }

    static func colorOf(_ p: JSONValue, _ key: String) -> PCColor? {
        guard p[key] != nil else { return nil }
        let c = Params.color(p, key, SIMD4(1, 0, 0, 1))
        return .rgb(c.x, c.y, c.z)
    }

    /// Photoshop's colours for new count groups, in order.
    static let groupColors: [SIMD3<Float>] = [SIMD3(1, 0, 0), SIMD3(0, 0.6, 1), SIMD3(0, 0.8, 0), SIMD3(1, 0.6, 0), SIMD3(0.8, 0, 0.8), SIMD3(1, 1, 0)]

    static func newGroup(_ d: Document, _ name: String?, _ color: PCColor?) -> CountGroup {
        let n = d.measurement.countGroups.count
        let c = groupColors[n % groupColors.count]
        return CountGroup(name: name ?? "Count Group \(n + 1)", color: color ?? .rgb(c.x, c.y, c.z))
    }

    static func countJSON(_ d: Document) -> JSONValue {
        let ms = d.measurement
        return [
            "total": .int(ms.countTotal),
            "activeGroup": .int(ms.activeCountGroup),
            "groups": .array(ms.countGroups.map { g in
                let c = g.color.rgb
                return ["name": .string(g.name), "color": .floats([c.x, c.y, c.z]), "markerSize": .int(g.markerSize), "labelSize": .int(g.labelSize),
                        "visible": .bool(g.visible), "count": .int(g.points.count), "points": .array(g.points.map(pointJSON))]
            }),
        ]
    }

    static func countAdd(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        guard let at = xy(p) ?? point(p["point"]) else { throw EngineError.bad("count.add", "pass `x` and `y`") }
        if !at.x.isFinite || !at.y.isFinite { throw EngineError.bad("count.add", "coordinates must be finite") }
        let gi = p["group"]?.uint64Value.map { Int(clamping: $0) }
        let n = try s.edit("Count") { d, _ -> Int in
            if d.measurement.countGroups.isEmpty {
                d.measurement.countGroups.append(newGroup(d, nil, nil))
                d.measurement.activeCountGroup = 0
            }
            let i = min(gi ?? d.measurement.activeCountGroup, d.measurement.countGroups.count - 1)
            guard i >= 0 else { throw EngineError.other("no such count group") }
            d.measurement.countGroups[i].points.append(at)
            return d.measurement.countGroups[i].points.count
        }
        return countJSON(try doc(s)).setting("number", .int(n))
    }

    /// Marker nearest `at` within `radius` px in group `g` (or any visible group).
    static func nearest(_ d: Document, _ at: SIMD2<Double>, _ radius: Double, _ g: Int?) -> (Int, Int)? {
        var best: (Double, Int, Int)?
        for (gi, grp) in d.measurement.countGroups.enumerated() {
            if let g, g != gi { continue }
            if !grp.visible { continue }
            for (pi, q) in grp.points.enumerated() {
                let dd = hypot(q.x - at.x, q.y - at.y)
                if dd <= radius && (best.map { dd < $0.0 } ?? true) { best = (dd, gi, pi) }
            }
        }
        return best.map { ($0.1, $0.2) }
    }

    static func locate(_ s: Session, _ p: JSONValue, _ cmd: String) throws -> (Int, Int) {
        let d = try doc(s)
        if let i = p["index"]?.uint64Value {
            guard let g = groupIndex(d, p) else { throw EngineError.bad(cmd, "no such count group") }
            if i < UInt64(d.measurement.countGroups[g].points.count) { return (g, Int(i)) }
            throw EngineError.bad(cmd, "no marker \(i)")
        }
        guard let at = xy(p) else { throw EngineError.bad(cmd, "pass `index` or `x`/`y`") }
        let radius = p["radius"]?.doubleValue ?? 6
        let g = p["group"]?.uint64Value.map { Int(clamping: $0) }
        guard let hit = nearest(d, at, radius, g) else { throw EngineError.other("no count marker there") }
        return hit
    }

    static func countRemove(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let (g, i) = try locate(s, p, "count.remove")
        try s.edit("Count") { d, _ in d.measurement.countGroups[g].points.remove(at: i) }
        return countJSON(try doc(s))
    }

    static func countMove(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        guard let to = point(p["to"]) else { throw EngineError.bad("count.move", "pass `to`: [x, y]") }
        let (g, i) = try locate(s, p, "count.move")
        try s.edit("Count") { d, _ in d.measurement.countGroups[g].points[i] = to }
        return countJSON(try doc(s))
    }

    static func countClear(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let d = try doc(s)
        let all = p["group"]?.stringValue == "all"
        var g: Int?
        if !all {
            guard let i = groupIndex(d, p) else { throw EngineError.bad("count.clear", "no such count group") }
            g = i
        }
        try s.edit("Clear Count") { d, _ in
            for i in d.measurement.countGroups.indices where g == nil || g == i { d.measurement.countGroups[i].points.removeAll() }
        }
        return countJSON(try doc(s))
    }

    static func countNewGroup(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let name = p["name"]?.stringValue
        let color = colorOf(p, "color")
        try s.edit("New Count Group") { d, _ in
            d.measurement.countGroups.append(newGroup(d, name, color))
            d.measurement.activeCountGroup = d.measurement.countGroups.count - 1
        }
        return countJSON(try doc(s))
    }

    static func countDeleteGroup(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let d = try doc(s)
        guard let g = groupIndex(d, p) else { throw EngineError.bad("count.deleteGroup", "no such count group") }
        try s.edit("Delete Count Group") { d, _ in
            d.measurement.countGroups.remove(at: g)
            let n = d.measurement.countGroups.count
            d.measurement.activeCountGroup = min(d.measurement.activeCountGroup, max(n - 1, 0))
        }
        return countJSON(try doc(s))
    }

    static func countSetGroup(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "count.setGroup"
        let d = try doc(s)
        guard let g = groupIndex(d, p) else { throw EngineError.bad(cmd, "no such count group") }
        var grp = d.measurement.countGroups[g]
        if let n = p["name"]?.stringValue { grp.name = n }
        if let c = colorOf(p, "color") { grp.color = c }
        if let v = p["markerSize"]?.uint64Value { grp.markerSize = min(max(UInt32(truncatingIfNeeded: v), 1), 10) }
        if let v = p["labelSize"]?.uint64Value { grp.labelSize = min(max(UInt32(truncatingIfNeeded: v), 8), 72) }
        if let v = p["visible"]?.boolValue { grp.visible = v }
        let activate = p["active"]?.boolValue == true || (p.objectValue.map { $0.count == 1 && $0["group"] != nil } ?? false)
        let changed = grp != d.measurement.countGroups[g]
        if changed || (activate && d.measurement.activeCountGroup != g) {
            try s.edit("Count Group Options") { d, _ in
                d.measurement.countGroups[g] = grp
                if activate { d.measurement.activeCountGroup = g }
            }
        }
        return countJSON(try doc(s))
    }

    // MARK: Record and log

    static func baseRow(_ d: Document, _ source: String, _ label: String, _ now: String) -> [String: JSONValue] {
        let sc = d.measurement.scale
        let src: String = switch source {
        case "selection": "Selection"
        case "ruler": "Ruler Tool"
        default: "Count Tool"
        }
        return ["label": .string(label), "dateTime": .string(now), "document": .string(d.name), "source": .string(src),
                "scale": .string(sc.describe), "scaleUnits": .string(sc.units), "scaleFactor": .number(sc.factor)]
    }

    static func featureValues(_ m: inout [String: JSONValue], _ f: Feature, _ count: Int, _ factor: Double) {
        m["count"] = .int(count)
        m["area"] = .number(round4(f.area * factor * factor))
        m["perimeter"] = .number(round4(f.perimeter * factor))
        m["circularity"] = .number(round4(f.circularity))
        m["height"] = .number(round4(Double(f.bounds.height) * factor))
        m["width"] = .number(round4(Double(f.bounds.width) * factor))
        m["grayMin"] = .number(round4(f.grayMin))
        m["grayMax"] = .number(round4(f.grayMax))
        m["grayMean"] = .number(round4(f.grayMean))
        m["grayMedian"] = .number(round4(f.grayMedian))
        m["integratedDensity"] = .number(round4(f.area * f.grayMean))
        m["histogram"] = .array(f.histogram.map { .int($0) })
    }

    static func record(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "image.analysis.recordMeasurements"
        let d = try doc(s)
        let source: String
        switch p["source"]?.stringValue ?? "auto" {
        case "auto":
            if d.selection != nil { source = "selection" } else if d.measurement.ruler != nil { source = "ruler" } else if d.measurement.countTotal > 0 {
                source = "count"
            } else { source = "selection" }
        case let x where ["selection", "ruler", "count"].contains(x): source = x
        case let other: throw EngineError.bad(cmd, "unknown source `\(other)` (auto|selection|ruler|count)")
        }
        // Numbered only once the rows exist, so a failed measurement does not use up a label.
        var st = s.state[Key.self]
        let label = "Measurement \(st.nextMeasurement + 1)"
        let now = p["dateTime"]?.stringValue ?? nowISO(s.services.clock())
        let factor = d.measurement.scale.factor
        var rows: [[String: JSONValue]] = []
        switch source {
        case "selection":
            let (sum, feats) = try selectionRows(s, d)
            var row = baseRow(d, source, label, now)
            featureValues(&row, sum, feats.count, factor)
            rows.append(row)
            if feats.count > 1 {
                for (i, f) in feats.enumerated() {
                    var row = baseRow(d, source, "Feature \(i + 1)", now)
                    featureValues(&row, f, 1, factor)
                    rows.append(row)
                }
            }
        case "ruler":
            guard let r = d.measurement.ruler else { throw EngineError.other("no ruler line to measure") }
            let info = rulerInfo(r, d.measurement.scale)
            var row = baseRow(d, source, label, now)
            row["length"] = info["length"] ?? .null
            row["angle"] = info["angle"] ?? .null
            rows.append(row)
        default:
            var row = baseRow(d, source, label, now)
            row["count"] = .int(d.measurement.countTotal)
            rows.append(row)
        }
        st.nextMeasurement += 1
        let keep = Set(st.dataPoints.of(source))
        var added: [JSONValue] = []
        for row in rows {
            st.nextRow += 1
            let r = LogRow(id: st.nextRow, values: row.filter { keep.contains($0.key) })
            st.log.append(r)
            added.append(r.json)
        }
        s.state[Key.self] = st
        return ["source": .string(source), "rows": .array(added)]
    }

    /// Columns any row has, in Photoshop's order.
    static func logColumns(_ rows: [LogRow]) -> [String] {
        columns.map(\.0).filter { k in rows.contains { $0.values[k] != nil } }
    }

    static func idsParam(_ p: JSONValue) -> [UInt64]? { p["rows"]?.arrayValue.map { $0.compactMap(\.uint64Value) } }

    static func logDelete(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        var st = s.state[Key.self]
        let before = st.log.count
        if let ids = idsParam(p) {
            st.log.removeAll { ids.contains($0.id) }
        } else if p["all"]?.boolValue == true {
            st.log.removeAll()
        } else {
            throw EngineError.bad("measurementLog.delete", "pass `rows`: [ids] or `all`: true")
        }
        s.state[Key.self] = st
        return ["deleted": .int(before - st.log.count), "remaining": .int(st.log.count)]
    }

    /// Integer-valued data points (serde writes them without ".0").
    static let integerKeys: Set<String> = ["count", "histogram"]

    /// One CSV field (photocraft `csv_field`: serde_json's text of numbers and arrays).
    static func csvField(_ v: JSONValue, integer: Bool = false) -> String {
        func text(_ v: JSONValue) -> String {
            switch v {
            case .string(let s): return s
            case .null: return ""
            case .bool(let b): return b ? "true" : "false"
            case .number(let n): return integer && n == n.rounded() && abs(n) < 9.2e18 ? String(Int64(n)) : jsonNumber(n)
            case .array, .object: return v.serialized()
            }
        }
        let s: String
        switch v {
        case .array(let a): s = a.map { $0.stringValue.map { "\"\($0)\"" } ?? text($0) }.joined(separator: " ")
        default: s = text(v)
        }
        if s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) {
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }

    /// The log (or the given rows) as CSV with Photoshop's column headers.
    static func logCSV(_ rows: [LogRow]) -> String {
        let cols = logColumns(rows)
        var out = cols.map { k in columns.first { $0.0 == k }?.1 ?? k }.joined(separator: ",") + "\n"
        for r in rows {
            out += cols.map { k in r.values[k].map { csvField($0, integer: integerKeys.contains(k)) } ?? "" }.joined(separator: ",") + "\n"
        }
        return out
    }

    static func logExport(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let log = s.state[Key.self].log
        let rows = idsParam(p).map { ids in log.filter { ids.contains($0.id) } } ?? log
        let csv = logCSV(rows)
        if let path = p["path"]?.stringValue {
            try s.services.fileSystem.write(path, Data(csv.utf8))
            return ["path": .string(path), "rows": .int(rows.count)]
        }
        return ["csv": .string(csv), "rows": .int(rows.count)]
    }

    // MARK: Scale marker

    /// A "nice" bar length (1, 2 or 5 × 10ⁿ) near a fifth of the image width, in logical units.
    static func niceLength(_ d: Document) -> Double {
        let target = Double(d.size.width) / 5 * d.measurement.scale.factor
        let e = pow(10, log10(target).rounded(.down))
        return [5.0, 2, 1].map { $0 * e }.first { $0 <= target } ?? e
    }

    /// The shortest image a scale bar fits: four times its 2 px minimum height (#932).
    static let minScaleMarkerHeight = 8.0

    /// Rust `f64 as i32`: saturating, NaN → 0.
    static func i32(_ v: Double) -> Int32 {
        if v.isNaN { return 0 }
        return Int32(max(min(v, Double(Int32.max)), Double(Int32.min)))
    }

    static func trimNum(_ v: Double) -> String {
        v.truncatingRemainder(dividingBy: 1) == 0 && abs(v) < 9.2e18 ? String(Int64(v)) : display(v)
    }

    static func placeScaleMarker(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "image.analysis.placeScaleMarker"
        let d = try doc(s)
        let sc = d.measurement.scale
        let length = p["length"]?.doubleValue ?? niceLength(d)
        if !(length > 0 && length.isFinite) { throw EngineError.bad(cmd, "length must be positive") }
        let px = length / sc.factor
        let (w, h) = (Double(d.size.width), Double(d.size.height))
        if px < 1 || px > w {
            throw EngineError.bad(cmd, "a \(display(length)) \(sc.units) bar is \(String(format: "%.1f", px)) px; it must fit the \(display(w)) px wide image")
        }
        // The bar is at least 2 px tall and at most a quarter of the image, so a shorter image has
        // no room for it (#932).
        if h < minScaleMarkerHeight {
            throw EngineError.bad(cmd, "the image is \(display(h)) px tall; a scale marker needs at least \(display(minScaleMarkerHeight)) px")
        }
        let fontSize = min(max(p["fontSize"]?.doubleValue ?? 12, 1), 1000)
        let font = p["font"]?.stringValue
        let showText = p["displayText"]?.boolValue ?? true
        let textTop: Bool
        switch p["textPosition"]?.stringValue ?? "bottom" {
        case "top": textTop = true
        case "bottom": textTop = false
        case let o: throw EngineError.bad(cmd, "textPosition `\(o)` (top|bottom)")
        }
        let rgb: SIMD3<Float>
        switch p["color"]?.stringValue ?? "black" {
        case "black": rgb = SIMD3(0, 0, 0)
        case "white": rgb = SIMD3(1, 1, 1)
        case let o: throw EngineError.bad(cmd, "color `\(o)` (black|white)")
        }
        // Bottom-left with a margin; the text sits under (or over) the bar.
        let margin = max((min(w, h) * 0.03).rounded(), 2)
        let barH = min(max((fontSize / 4).rounded(), 2), h / 4)
        let textH = showText ? fontSize * 1.25 : 0
        // Keep the bar on the canvas when the text under it doesn't fit; the label is clipped (#932).
        let barY = max(textTop ? h - margin - barH : h - margin - barH - textH, 0)
        // Likewise pull a bar nearly as wide as the image in from the right edge (#932).
        let barX = min(margin, w - px)
        let bar = PixelRect(x0: i32(barX.rounded()), y0: i32(barY.rounded()), x1: i32((barX + px).rounded()), y1: i32((barY + barH).rounded()))
        let label = "\(trimNum(length)) \(sc.units)"
        return try compound(s, "Place Scale Marker") { s in
            let fmt = try doc(s).pixelFormat
            let barId = try s.edit("Place Scale Marker") { doc, active -> LayerId in
                var l = Layer.raster("Scale Bar", format: fmt)
                l.withRaster { $0.fill(bar, with: fmt.components(fromRGBA: SIMD4(rgb.x, rgb.y, rgb.z, 1))) }
                let id = l.id
                doc.layers.append(Layer.group("Measurement Scale Marker", [l]))
                active = id
                return id
            }
            var textLayer: JSONValue = .null
            if showText {
                let baseline = textTop ? Double(bar.y0) - fontSize * 0.3 : Double(bar.y1) + fontSize
                var tp: JSONValue = ["x": .int(bar.x0), "y": .number(baseline), "text": .string(label), "size": .number(fontSize),
                                     "color": .floats([rgb.x, rgb.y, rgb.z, 1]), "name": .string(label)]
                if let font { tp = tp.setting("font", .string(font)) }
                textLayer = try s.execute("type.create", tp)["layer"] ?? .null
            }
            let group = try doc(s).layers.last.map { JSONValue.id($0.id) } ?? .null
            return ["group": group, "bar": .id(barId), "text": textLayer, "barRect": [.int(bar.x0), .int(bar.y0), .int(bar.x1), .int(bar.y1)],
                    "pixels": .number(px), "label": .string(label)]
        }
    }

    // MARK: Info

    static func analysisInfo(_ s: Session) throws -> JSONValue {
        let d = try doc(s)
        let ms = d.measurement
        return [
            "scale": scaleJSON(ms.scale),
            "ruler": ms.ruler.map { r in rulerJSON(r).setting("info", rulerInfo(r, ms.scale)) } ?? .null,
            "count": countJSON(d),
            "notes": .int(d.notes.count),
            "logRows": .int(s.state[Key.self].log.count),
        ]
    }

    // MARK: Registration

    static func register(into r: inout CommandRegistry) {
        let always: CommandEnabled = Pre.always
        r.add([
            CommandSpec("image.analysis.setMeasurementScale", "Set Measurement Scale…", menu: ["Image", "Analysis"],
                        params: #"{"preset":"default|custom"="custom","pixelLength":px,"logicalLength":number,"units":str (e.g. "mm")} (no params: read the scale)"#,
                        module: m, enabled: hasDoc) { s, p in try setScale(s, p) },
            CommandSpec("image.analysis.selectDataPoints", "Select Data Points…", menu: ["Image", "Analysis"],
                        params: #"{"selection":[keys]|{key:bool}?,"ruler":[keys]|{key:bool}?,"count":[keys]|{key:bool}?,"reset":bool=false} (keys: label,dateTime,document,source,scale,scaleUnits,scaleFactor,count,area,perimeter,circularity,height,width,grayMin,grayMax,grayMean,grayMedian,integratedDensity,histogram,length,angle)"#,
                        module: m, enabled: always) { s, p in try selectDataPoints(s, p) },
            CommandSpec("image.analysis.recordMeasurements", "Record Measurements", menu: ["Image", "Analysis"],
                        params: #"{"source":"auto|selection|ruler|count"="auto"} → appended Measurement Log rows (selection: summary + one row per feature)"#,
                        module: m, enabled: hasDoc) { s, p in try record(s, p) },
            CommandSpec("image.analysis.rulerTool", "Ruler Tool", menu: ["Image", "Analysis"],
                        params: #"{"start":[x,y],"end":[x,y],"protractor":[x,y]|null?,"clear":bool=false} (no params: read) → X/Y/W/H/angle/L1/L2"#,
                        module: m, enabled: hasDoc) { s, p in try rulerTool(s, p) },
            CommandSpec("image.analysis.countTool", "Count Tool", menu: ["Image", "Analysis"],
                        params: #"{} → count groups and markers (edit with count.*)"#,
                        module: m, journal: false, enabled: hasDoc) { s, _ in countJSON(try doc(s)) },
            CommandSpec("image.analysis.placeScaleMarker", "Place Scale Marker…", menu: ["Image", "Analysis"],
                        params: #"{"length":logical units=nice ≈ width/5,"font":str?,"fontSize":pt=12,"displayText":bool=true,"textPosition":"top|bottom"="bottom","color":"black|white"="black"}"#,
                        module: m, enabled: hasDoc) { s, p in try placeScaleMarker(s, p) },
            straightenSpec,
            CommandSpec("image.analysis.info", "Analysis Info", params: #"{} → scale, ruler readout, count groups, note and log counts"#,
                        module: m, journal: false, enabled: hasDoc) { s, _ in try analysisInfo(s) },
            CommandSpec("count.add", "Add Count", params: #"{"x":px,"y":px,"group":index?}"#, module: m, enabled: hasDoc) { s, p in try countAdd(s, p) },
            CommandSpec("count.remove", "Remove Count", params: #"{"index":n,"group":index?} | {"x":px,"y":px,"radius":px=6}"#,
                        module: m, enabled: hasDoc) { s, p in try countRemove(s, p) },
            CommandSpec("count.move", "Move Count", params: #"{"index":n,"group":index?,"to":[x,y]} | {"x":px,"y":px,"to":[x,y]}"#,
                        module: m, enabled: hasDoc) { s, p in try countMove(s, p) },
            CommandSpec("count.clear", "Clear Count", params: #"{"group":index|"all"=active}"#, module: m, enabled: hasDoc) { s, p in try countClear(s, p) },
            CommandSpec("count.newGroup", "New Count Group", params: ##"{"name":str?,"color":"#rrggbb"|[r,g,b]?}"##,
                        module: m, enabled: hasDoc) { s, p in try countNewGroup(s, p) },
            CommandSpec("count.deleteGroup", "Delete Count Group", params: #"{"group":index=active}"#,
                        module: m, enabled: hasDoc) { s, p in try countDeleteGroup(s, p) },
            CommandSpec("count.setGroup", "Count Group Options",
                        params: ##"{"group":index=active,"name":str?,"color":"#rrggbb"|[r,g,b]?,"markerSize":1..10?,"labelSize":8..72?,"visible":bool?,"active":bool?}"##,
                        module: m, enabled: hasDoc) { s, p in try countSetGroup(s, p) },
            CommandSpec("measurementLog.list", "Measurement Log", params: #"{} → rows and columns"#, module: m, journal: false, enabled: always) { s, _ in
                let log = s.state[Key.self].log
                return ["rows": .array(log.map(\.json)), "columns": .strings(logColumns(log))]
            },
            CommandSpec("measurementLog.delete", "Delete Measurements", params: #"{"rows":[ids]}|{"all":true}"#,
                        module: m, enabled: hasLog) { s, p in try logDelete(s, p) },
            CommandSpec("measurementLog.export", "Export Measurements…",
                        params: #"{"path":str? (CSV file; omitted → returns the CSV text),"rows":[ids]?}"#,
                        module: m, enabled: always) { s, p in try logExport(s, p) },
        ])
    }
}
