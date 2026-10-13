// Tests ported from photocraft-io (crates/io/src/camera_raw_map.rs `#[cfg(test)]`; the ignored
// `all_sliders_fixture` needs a whole PSD import and a user-supplied file and is not ported), and
// the serde round trip of photocraft-algo's `CameraRaw` (crates/algo/src/camera_raw.rs test
// `new_curves_are_validated_but_saved_curves_still_load_and_render`, parameter part), MIT OR
// Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import PCDocument
import PCFoundation
import PCIOCore
@testable import PCIOSmart
import PCPSD
import Testing

@Suite struct CameraRawMapTests {
    typealias C = CameraRawMap

    static func fltr(_ item: PSDDescriptor) -> PSDDescriptor { SmartMap.getDesc(item, "Fltr") ?? PSDDescriptor() }

    static func withFltr(_ item: PSDDescriptor, _ edit: (inout PSDDescriptor) -> Void) -> PSDDescriptor {
        var i = item
        var f = fltr(i)
        edit(&f)
        SmartMap.set(&i, "Fltr", .descriptor(f))
        return i
    }

    static func ints(_ v: [Int32]) -> DValue { .list(v.map { .integer($0) }) }

    // Parameter values observed in the supplied 18.4 PSD. No source pixels or private document
    // metadata are included in this synthetic regression fixture.
    static func sourceItem() -> PSDDescriptor {
        var d = PSDDescriptor(classID: DID(C.className))
            .with("CrVe", .text(.nulTerminated("18.4")))
            .with("PrVN", .integer(6))
            .with("PrVe", .integer(251_920_384))
            .with("Ex12", .double(1.15))
        for (key, value): (String, Int32) in [
            ("Cr12", -38), ("Hi12", 35), ("Sh12", -50), ("Wh12", 49), ("Bk12", -34), ("PC_S", 0), ("PC_D", -21), ("PC_L", 38),
            ("PC_H", 0), ("PC_1", 25), ("PC_2", 50), ("PC_3", 75),
        ] {
            d = d.with(key, .integer(value))
        }
        for (_, keys) in C.arrays.dropFirst() {
            for key in keys {
                let value: Int32 = switch key {
                case "HA_R": -50
                case "HA_Y": 29
                case "HA_G": 1
                default: 0
                }
                d = d.with(key, .integer(value))
            }
        }
        let f = SmartFilter(command: C.command, params: .null)
        return PSDDescriptor(classID: "filterFX")
            .with("Nm  ", .text(.nulTerminated("Camera Raw Filter")))
            .with("blendOptions", SmartMap.blendOptions(f))
            .with("enab", .boolean(true))
            .with("hasoptions", .boolean(true))
            .with("FrgC", SmartMap.rgbc(0))
            .with("BckC", SmartMap.rgbc(255))
            .with("Fltr", .descriptor(d))
            .with("filterID", .integer(C.filterID))
    }

    static func allControlsItem() -> PSDDescriptor {
        withFltr(sourceItem()) { d in
            SmartMap.set(&d, "WBal", .enumerated(type: "WBal", value: "Cst "))
            SmartMap.set(&d, "ShpR", .double(1.2))
            for (key, value): (String, Int32) in [
                ("Temp", -26), ("Tint", -25), ("CrTx", -31), ("Cl12", 30), ("Dhze", -34), ("Vibr", 33), ("Strt", 33), ("Shrp", 43),
                ("ShpD", 36), ("ShpM", 30), ("LNR ", 47), ("LNRD", 50), ("CNR ", 25), ("CNRD", 50), ("STSH", 117), ("STSS", 52),
                ("STHH", 316), ("STHS", 70), ("STB ", 35), ("CgMH", 51), ("CgMS", 51), ("CgSL", -24), ("CgML", 41), ("CgHL", 28),
                ("CgBl", 36), ("CgGH", 20), ("CgGS", 61), ("CgGL", 45), ("GRNA", 45), ("GRNS", 25), ("GRNF", 50), ("PCVA", 31),
                ("PCVM", 50), ("PCVF", 50), ("PCVR", 0),
            ] {
                SmartMap.set(&d, key, .integer(value))
            }
            for (key, neutral) in C.neutralOnly { SmartMap.set(&d, key, .integer(neutral)) }
            for (key, x, y): (String, Int32, Int32) in [("Crv ", 146, 102), ("CrvR", 90, 174), ("CrvG", 162, 122), ("CrvB", 129, 202)] {
                SmartMap.set(&d, key, ints([0, 0, x, y, 255, 255]))
            }
        }
    }

    static func setting(_ params: JSONValue, _ name: String, _ value: JSONValue) -> JSONValue {
        var p = params
        _ = C.setParam(&p, name, value)
        return p
    }

    @Test func allObservedDevelopControlsRoundTripAndPatchOnlyTheEditedField() throws {
        let source = Self.allControlsItem()
        let f = SmartMap.filterFromItem(source)
        #expect(f.command == C.command)
        #expect(f.params["temperature"] == -26.0)
        #expect(f.params["texture"] == -31.0)
        #expect(abs((f.params["sharpenRadius"]?.doubleValue ?? 0) - 1.2) < 1e-6)
        #expect(f.params["gradeHighlights"] == ["hue": 316.0, "sat": 70.0, "lum": 28.0])
        #expect(f.params["pointCurveBlue"] == [[0.0, 0.0], [129.0, 202.0], [255.0, 255.0]])
        #expect(try SmartMap.itemForFilter(f) == source)
        let defaults = C.defaultParams()
        for (param, key) in C.scalars {
            var edited = f
            var number = try #require(C.getParam(defaults, param)?.doubleValue)
            if C.getParam(f.params, param)?.doubleValue == number { number += 1 }
            edited.params = Self.setting(edited.params, param, .number(number))
            let expected = Self.withFltr(source) {
                SmartMap.set(&$0, key, C.isDoubleKey(key) ? .double(number) : .integer(Int32(number)))
            }
            #expect(Self.fltr(try SmartMap.itemForFilter(edited)) == Self.fltr(expected), "\(param)")
        }
        for (param, key) in C.curves {
            var edited = f
            edited.params = Self.setting(edited.params, param, [])
            let item = try SmartMap.itemForFilter(edited)
            let expected = Self.withFltr(source) { SmartMap.set(&$0, key, Self.ints([0, 0, 255, 255])) }
            #expect(Self.fltr(item) == Self.fltr(expected), "\(param)")
            #expect(SmartMap.filterFromItem(item).params[param] == [], "\(param)")
        }
    }

    @Test func activeUnimplementedControlsAndMalformedCurvesStayOpaque() throws {
        for (key, neutral) in C.neutralOnly {
            let item = Self.withFltr(Self.allControlsItem()) { SmartMap.set(&$0, key, .integer(neutral + 1)) }
            let f = SmartMap.filterFromItem(item)
            #expect(f.command == SmartMap.unsupportedFilter, "\(key)")
            #expect(try SmartMap.itemForFilter(f) == item, "\(key)")
        }
        for value: DValue in [
            .list([.integer(0)]),
            Self.ints([0, 0, 0, 255]),
            Self.ints([0, 0, 255, 256]),
            .list([DValue](repeating: .double(0), count: 4)),
            .list([DValue](repeating: .integer(0), count: 34)),
        ] {
            let item = Self.withFltr(Self.allControlsItem()) { SmartMap.set(&$0, "Crv ", value) }
            let f = SmartMap.filterFromItem(item)
            #expect(f.command == SmartMap.unsupportedFilter)
            #expect(try SmartMap.itemForFilter(f) == item)
        }
    }

    @Test func lightCurveAndHslAreEditableWithoutRewritingUnchangedSettings() throws {
        let source = Self.sourceItem().with("futureOuterData", .rawData(Data([1, 2, 3, 4])))
        var f = SmartMap.filterFromItem(source)
        #expect(f.command == C.command)
        #expect(abs((f.params["exposure"]?.doubleValue ?? 0) - 1.15) < 1e-6)
        #expect(f.params["exposure"]?.doubleValue == Double(Float(1.15)), "the f32 value, as photocraft's editor holds it")
        #expect(f.params["contrast"] == -38.0)
        #expect(f.params["curveDarks"] == -21.0)
        #expect(f.params["curveLights"] == 38.0)
        #expect(f.params["curveSplits"] == [25.0, 50.0, 75.0])
        #expect(f.params["hslHue"] == [-50.0, 0.0, 29.0, 1.0, 0.0, 0.0, 0.0, 0.0])
        #expect(try SmartMap.itemForFilter(f) == source)
        f.params = Self.setting(f.params, "exposure", 0.0)
        var hsl = try #require(f.params["hslHue"]?.arrayValue)
        hsl[2] = -20.0
        f.params = Self.setting(f.params, "hslHue", .array(hsl))
        f.visible = false
        f.opacity = 0.4
        f.blend = .multiply
        let edited = try SmartMap.itemForFilter(f)
        let expected = Self.withFltr(source) {
            SmartMap.set(&$0, "Ex12", .double(0))
            SmartMap.set(&$0, "HA_Y", .integer(-20))
        }
        #expect(Self.fltr(edited) == Self.fltr(expected))
        #expect(edited["futureOuterData"] == source["futureOuterData"])
        let back = SmartMap.filterFromItem(edited)
        #expect(back.visible == false && back.blend == .multiply && back.opacity == 0.4)
        #expect(back.params["exposure"] == 0.0)
        #expect(back.params["hslHue"]?[2] == -20.0)
    }

    @Test func newFiltersWriteEveryVerifiedControlAndAcceptExplicitDefaults() throws {
        var params = C.defaultParams()
        guard case var .object(o) = params else {
            Issue.record("defaults are not an object")
            return
        }
        o["seed"] = 0
        params = .object(o)
        for (param, key) in C.scalars {
            let number = switch key {
            case "Ex12": 0.75
            case "ShpR": 1.2
            default: 12.0
            }
            params = Self.setting(params, param, .number(number))
        }
        guard case var .object(o2) = params else { return }
        for (param, keys) in C.arrays {
            o2[param] = param == "curveSplits" ? [20, 45, 80] : .array((0 ..< keys.count).map { .number(Double($0) + 1) })
        }
        params = .object(o2)
        let f = SmartFilter(command: C.command, params: params, blend: .screen, opacity: 0.5, visible: false)
        let item = try SmartMap.itemForFilter(f)
        let back = SmartMap.filterFromItem(try PSDDescriptor(bytes: item.serializedBytes()))
        #expect(back.command == f.command && back.visible == false && back.blend == .screen && back.opacity == 0.5)
        // Compare slider numbers after both sides have been normalised through CameraRaw.
        let expected = try CameraRawSettings(json: params).json
        for param in C.scalars.map(\.param) + C.arrays.map(\.param) {
            #expect(C.getParam(back.params, param) == C.getParam(expected, param), "\(param)")
        }
    }

    @Test func unsupportedProcessingSettingsRemainOpaqueAndLossless() throws {
        for (key, value): (String, DValue) in [
            ("LCs ", .text(PSDUnicodeString("unknown masks"))),
            ("PrVN", .integer(7)),
            ("PrVe", .integer(123)),
            ("Ex12", .double(.infinity)),
            ("Cr12", .text(PSDUnicodeString("bad type"))),
        ] {
            let item = Self.withFltr(Self.sourceItem()) { SmartMap.set(&$0, key, value) }
            let f = SmartMap.filterFromItem(item)
            #expect(f.command == SmartMap.unsupportedFilter, "\(key)")
            #expect(try SmartMap.itemForFilter(f) == item, "\(key)")
        }
    }

    @Test func fractionalSliderLevelsRoundInsteadOfDroppingTheFilter() throws {
        var f = SmartMap.filterFromItem(Self.sourceItem())
        f.params = Self.setting(f.params, "contrast", -12.4)
        var hsl = try #require(f.params["hslHue"]?.arrayValue)
        hsl[0] = 10.5
        f.params = Self.setting(f.params, "hslHue", .array(hsl))
        f.params = Self.setting(f.params, "gradeShadows.hue", 359.7)
        f.params = Self.setting(f.params, "pointCurve", [[0, 0], [100.2, 120.6], [200.6, 180.4], [255, 255]])
        let item = try SmartMap.itemForFilter(f)
        let d = Self.fltr(item)
        #expect(d["Cr12"] == .integer(-12))
        #expect(d["HA_R"] == .integer(11))
        #expect(d["STSH"] == .integer(0))
        #expect(d["Crv "] == Self.ints([0, 0, 100, 121, 201, 180, 255, 255]))
        let back = SmartMap.filterFromItem(item)
        #expect(back.command == C.command)
        #expect(back.params["contrast"] == -12.0)
    }

    @Test func unsupportedOrMalformedExportsReportErrors() throws {
        for params: JSONValue in [
            .null,
            ["exposure": "bright"],
            ["exposure": 1e40],
            ["exposure": 6],
            ["contrast": 101],
            ["hslHue": [1, 2]],
            ["curveSplits": [80, 50, 20]],
            ["curveSplits": [25, 25, 75]],
            ["pointCurve": [[0, 0], [0, 255]]],
            ["sharpenRadius": 4],
            ["gradeShadows": ["hue": 361]],
            ["gradeShadows": ["unknown": 1]],
            ["seed": 1],
            ["vignetteHighlights": 10],
            ["futureSetting": 1],
            [C.templateKey: "zz"],
            [C.templateKey: "00"],
            [C.templateKey: 12],
            [C.templateKey: .string(String(repeating: "0", count: C.maxTemplateBytes * 2 + 1))],
        ] {
            #expect(throws: PCIOError.self, "\(params.jsonString.prefix(80))") { try C.exportItem(params) }
        }
        let wrong = PSDDescriptor(classID: "filterFX").with("filterID", .integer(1))
        #expect(throws: PCIOError.self) { try C.exportItem([C.templateKey: .string(SmartMap.toHex(wrong.serializedBytes()))]) }
        // The finite-check message names the PSD key, as photocraft's does.
        #expect(throws: PCIOError.unsupported("Camera Raw Ex12 must be finite")) { try C.exportItem(["exposure": 1e40]) }
    }

    // MARK: photocraft-algo `CameraRaw` (serde shape)

    @Test func newCurvesAreValidatedButSavedCurvesStillLoad() throws {
        for field in ["pointCurve", "pointCurveRed", "pointCurveGreen", "pointCurveBlue"] {
            let bad: [JSONValue] = [
                [[128, 128]], [[255, 255], [0, 0]], [[0, 0], [0, 255]], [[0, -1], [255, 255]], [[0, 0], [256, 255]],
                [[0, 0], [1e30, 255]], .array((0 ..< 17).map { .array([.number(Double($0 * 15)), .number(Double($0 * 15))]) }),
            ]
            for points in bad {
                let p = try CameraRawSettings(json: [field: points])
                #expect(p.validate() != nil, "\(field): \(points)")
            }
            let good: [JSONValue] = [[], [[0, 0], [255, 255]], .array((0 ..< 16).map { .array([.number(Double($0 * 17)), .number(Double($0 * 17))]) })]
            for points in good {
                let p = try CameraRawSettings(json: [field: points])
                #expect(p.validate() == nil, "\(field): \(points)")
            }
        }
        #expect(try CameraRawSettings(json: [:]) == CameraRawSettings())
        // serde's JSON of the defaults, f32 values as their f64, every key present.
        let d = CameraRawSettings().json
        #expect(d.objectValue?.count == 51)
        #expect(d["curveSplits"] == [25, 50, 75] && d["vignetteStyle"] == "highlightPriority" && d["seed"] == 0)
        #expect(d["gradeGlobal"] == ["hue": 0, "sat": 0, "lum": 0] && d["pointCurve"] == [])
        // Codable goes through the same shape.
        let encoded = try JSONEncoder().encode(CameraRawSettings())
        #expect(try JSONDecoder().decode(CameraRawSettings.self, from: encoded) == CameraRawSettings())
        // Type errors, fixed lengths and unknown keys as serde treats them.
        #expect(throws: PCIOError.self) { try CameraRawSettings(json: ["exposure": .null]) }
        #expect(throws: PCIOError.self) { try CameraRawSettings(json: ["hslSat": [1, 2, 3]]) }
        #expect(throws: PCIOError.self) { try CameraRawSettings(json: ["seed": -1]) }
        #expect(throws: PCIOError.self) { try CameraRawSettings(json: ["vignetteStyle": 1]) }
        #expect(try CameraRawSettings(json: ["unknown": 1, "gradeShadows": [10, 20]]).gradeShadows == .init(hue: 10, sat: 20, lum: 0))
        #expect(try CameraRawSettings(json: ["exposure": 1e40]).json["exposure"] == .null, "out of f32 range: infinite, written as null")
    }
}
