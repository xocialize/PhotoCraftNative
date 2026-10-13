// Port of photocraft-engine (crates/engine/src/preset_import_cmds.rs `mod tests`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Every photocraft test is ported. The `.abr` / `.grd` files are written with PCPSD's writers
// (photocraft-psd's `write_v12` / `write_v6` / `grd::write`).

import Foundation
import PCDocument
@testable import PCEngine
import PCPaint
import PCPSD
import Testing

@Suite struct PresetImportTests {
    typealias PI = PresetImportCommands

    func abrV2() throws -> [UInt8] {
        let tip = PSDAbr.Sample(id: "", width: 6, height: 4, depth: 8, data: [UInt8](repeating: 255, count: 24))
        return [UInt8](try PSDAbr.writeV12(version: 2, [
            PSDAbr.LegacyBrush(name: "Hard Round", spacing: 25, antiAlias: true, tip: .sampled(tip)),
            PSDAbr.LegacyBrush(name: "", spacing: 10, antiAlias: true, tip: .computed(diameter: 9, hardness: 100, angle: 0, roundness: 100)),
        ], rle: true))
    }

    @Test func importAddsAGroupAndPaints() throws {
        let s = Session()
        let before = s.tools.presets.count
        let data = Base64.encode(try abrV2())
        let r = try s.execute("brush.presets.importAbr", ["data": .string(data), "group": "Legacy", "select": true])
        #expect(r["count"] == 2)
        // The name clashing with the built-in Hard Round is made unique.
        #expect(r["imported"] == .strings(["Hard Round 2", "9 px Round"]))
        #expect(s.tools.presets.count == before + 2)
        #expect(s.tools.presets.filter { $0.group == "Legacy" }.allSatisfy { !$0.builtin })
        if case .sampled = s.tools.brush.tip {} else { Issue.record("the selected preset's sampled tip is current") }
        // Re-import replaces the group.
        try s.execute("brush.presets.importAbr", ["data": .string(data), "group": "Legacy"])
        #expect(s.tools.presets.count == before + 2)
        // Imported presets paint.
        try s.execute("file.new", ["width": 64, "height": 64])
        try s.execute("paint.stroke", ["points": [[5, 30], [60, 30]], "preset": "9 px Round"])
        // From a file on disk, the group defaults to the file name.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pc-abr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("My Set.abr")
        let preset = PSDDescriptor(classID: "brushPreset")
            .with("Nm  ", .text(.nulTerminated("Speckle")))
            .with("Brsh", .descriptor(PSDDescriptor(classID: "sampledBrush").with("sampledData", .text(.nulTerminated("$s")))))
        let tip = PSDAbr.Sample(id: "$s", width: 5, height: 5, depth: 16, data: [UInt8](repeating: 0x80, count: 50))
        try PSDAbr.writeV6(subversion: 2, samples: [tip], patterns: [], presets: [preset], rle: true).write(to: path)
        let r2 = try s.execute("brush.presets.importAbr", ["path": .string(path.path)])
        #expect(r2["group"]?.stringValue == "My Set")
        #expect(r2["imported"]?[0]?.stringValue == "Speckle")
        #expect(r2["version"]?.intValue == 6)
    }

    @Test func badParamsFailGracefully() throws {
        let s = Session()
        let n = s.tools.presets.count
        let v2 = try abrV2()
        let cases: [JSONValue] = [
            [:],
            ["path": ""],
            ["path": "/nonexistent/brushes.abr"],
            ["data": 42],
            ["data": "%%%not base64"],
            ["data": ""],
            ["data": "AAAA"],
            ["data": .string(Base64.encode(Array("8BPS\u{0}\u{1}junk".utf8)))],
            ["data": .string(Base64.encode(v2)), "group": 5],
            ["data": .string(Base64.encode(v2)), "group": "  "],
            ["data": .string(Base64.encode(Array(v2.prefix(20))))],
        ]
        for p in cases {
            #expect(throws: (any Error).self, "\(p)") { try s.execute("brush.presets.importAbr", p) }
        }
        #expect(s.tools.presets.count == n)
    }

    @Test func grdImportAddsAGradientGroup() throws {
        let grads = [
            PSDGrd.Gradient(name: "Ember", noise: false,
                            stops: [PSDGrd.Stop(location: 1, midpoint: 0.5, color: .rgb(1, 0, 0)),
                                    PSDGrd.Stop(location: 0, midpoint: 0.5, color: .foreground)],
                            opacity: [(location: 0, opacity: 1, midpoint: 0.5), (location: 1, opacity: 0, midpoint: 0.5)]),
            PSDGrd.Gradient(name: "Static", noise: true),
        ]
        let s = Session()
        let data = Base64.encode([UInt8](PSDGrd.write(grads)))
        let r = try s.execute("gradient.presets.importGrd", ["data": .string(data), "group": "Fire"])
        #expect(r["imported"] == .strings(["Ember"]))
        #expect(r["warnings"]?.arrayValue?.count == 1)
        let g = try #require(s.state[PresetCommands.Key.self].gradients.first { $0.name == "Fire" })
        #expect(g.items[0].stops == [PresetCommands.GradientStop(0, .foreground), PresetCommands.GradientStop(1, .rgb(SIMD3(1, 0, 0)))])
        #expect(g.items[0].opacity == [OpacityStop(0, 1), OpacityStop(1, 0)])
        // Re-import replaces the group.
        let n = s.state[PresetCommands.Key.self].gradients.count
        try s.execute("gradient.presets.importGrd", ["data": .string(data), "group": "Fire"])
        #expect(s.state[PresetCommands.Key.self].gradients.count == n)
        let bad: [JSONValue] = [[:], ["data": "@@"], ["data": .string(Base64.encode(Array("8BGR\u{0}\u{3}".utf8)))], ["path": "/nope.grd"]]
        for p in bad {
            #expect(throws: (any Error).self, "\(p)") { try s.execute("gradient.presets.importGrd", p) }
        }
        let onlyNoise = Base64.encode([UInt8](PSDGrd.write(Array(grads[1...]))))
        #expect(throws: (any Error).self) { try s.execute("gradient.presets.importGrd", ["data": .string(onlyNoise)]) }
    }

    @Test func colourConversions() {
        #expect(PI.hsbToRGB(SIMD3(120, 1, 1)) == SIMD3(0, 1, 0))
        let w = PI.labToRGB(SIMD3(100, 0, 0))
        #expect([w.x, w.y, w.z].allSatisfy { abs($0 - 1) < 0.01 }, "\(w)")
        let k = PI.labToRGB(SIMD3(0, 0, 0))
        #expect([k.x, k.y, k.z].allSatisfy { $0 < 0.01 }, "\(k)")
    }

    @Test func uniqueNames() {
        let taken = ["A", "a 2"]
        #expect(PI.unique("a", taken) == "a 3")
        #expect(PI.unique("B", taken) == "B")
    }

    /// Not a photocraft test: the mapping of a v6 preset's dynamics, texture and dual brush.
    @Test func v6PresetSettingsMapOntoTheBrush() throws {
        let tip = PSDAbr.Sample(id: "$t", width: 4, height: 4, depth: 8, data: [UInt8](repeating: 200, count: 16))
        let brsh = PSDDescriptor(classID: "sampledBrush")
            .with("sampledData", .text(.nulTerminated("$t")))
            .with("Dmtr", .unitFloat(unit: "#Pxl", value: 30))
            .with("Spcn", .unitFloat(unit: "#Prc", value: 40))
        let preset = PSDDescriptor(classID: "brushPreset")
            .with("Nm  ", .text(.nulTerminated("Dyn")))
            .with("Brsh", .descriptor(brsh))
            .with("useTipDynamics", .boolean(true))
            .with("szVr", .descriptor(PSDDescriptor(classID: "brVr").with("bVTy", .integer(2)).with("jitter", .unitFloat(unit: "#Prc", value: 25))))
            .with("useTexture", .boolean(true))
            .with("textureBlendMode", .enumerated(type: "BlnM", value: "CBrn"))
            .with("Txtr", .descriptor(PSDDescriptor(classID: "Ptrn").with("Nm  ", .text(.nulTerminated("Missing")))))
            .with("mysteryKey", .boolean(true))
        let f = try PSDAbr.parse(PSDAbr.writeV6(subversion: 2, samples: [tip], patterns: [], presets: [preset], rle: false))
        let imp = try PI.Abr.map(f, group: "G")
        let b = try #require(imp.presets.first).brush
        #expect(b.size == 30 && abs(b.spacing - 0.4) < 1e-6)
        #expect(b.shapeDynamics.enabled && b.shapeDynamics.size.control == .penPressure && abs(b.shapeDynamics.size.jitter - 0.25) < 1e-6)
        #expect(b.texture.enabled && b.texture.mode == .colorBurn)
        if case .procedural(.paper, 128, 1) = b.texture.pattern {} else { Issue.record("a missing texture becomes paper") }
        #expect(imp.warnings.contains { $0.contains("Missing") })
        #expect(imp.warnings.contains { $0.contains("mysteryKey") })
    }
}
