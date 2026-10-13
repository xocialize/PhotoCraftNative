// Port of photocraft-engine (crates/engine/src/swatch_cmds/tests.rs and crates/engine/src/presets/swatches.rs `mod tests`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Every photocraft test is ported; the `.aco` / `.ase` fixtures are written with PCPSD
// (photocraft-psd's `aco::write` / `ase::write`).

import Foundation
import PCDocument
@testable import PCEngine
import PCFoundation
import PCPaint
import PCPSD
import Testing

@Suite struct SwatchTests {
    typealias SC = SwatchCommands

    func names(_ s: Session) -> [String] { s.state[SC.LibraryKey.self].groups.flatMap { $0.items.map(\.name) } }
    func groups(_ s: Session) -> [SC.Group] { s.state[SC.LibraryKey.self].groups }

    @Test func defaultsAndListing() throws {
        let s = Session()
        let r = try s.execute("swatches.list")
        #expect(r["count"]?.intValue == 40)
        #expect(r["groups"]?[0]?["name"] == "Grays")
        #expect(r["groups"]?[0]?["swatches"]?[0] == ["name": "Black", "model": "rgb", "values": [0.0, 0.0, 0.0], "hex": "#000000"])
        #expect(r["groups"]?[2]?["swatches"]?[0]?["hex"] == "#e62828")
    }

    @Test func addFromForegroundAndExplicitModels() throws {
        let s = Session()
        s.tools.foreground = SIMD4(1, 0.5, 0, 1)
        let r = try s.execute("swatches.add")
        #expect(r["name"] == "Color Swatch 1" && r["group"] == "Grays")
        #expect(groups(s)[0].items.last?.color == .rgb(SIMD3(1, 0.5, 0)))
        #expect(try s.execute("swatches.add")["name"] == "Color Swatch 2")
        // CMYK into a new group at the front, spot.
        let c = try s.execute("swatches.add", ["name": "Ink", "group": "Print", "index": 0, "kind": "spot", "color": ["model": "cmyk", "values": [100, 0, 0, 0]]])
        #expect(c["group"] == "Print")
        #expect(groups(s).last?.items[0] == SC.Swatch(name: "Ink", color: .cmyk(SIMD4(1, 0, 0, 0)), kind: .spot))
        // Names stay unique.
        #expect(try s.execute("swatches.add", ["name": "Ink"])["name"] == "Ink 2")
    }

    @Test func useSetsForegroundAndBackgroundThroughColourManagement() throws {
        let s = Session()
        try s.execute("swatches.use", ["swatch": "Red"])
        #expect(s.tools.foreground == SIMD4<Float>(230 / 255, 40 / 255, 40 / 255, 1))
        try s.execute("swatches.use", ["index": 9, "target": "background"])
        #expect(s.tools.background == SIMD4(1, 1, 1, 1), "index 9 is White")
        try s.execute("swatches.add", ["name": "Lab white", "color": ["model": "lab", "values": [100, 0, 0]]])
        #expect(try s.execute("swatches.use", ["swatch": "Lab white"])["hex"] == "#ffffff")
        try s.execute("swatches.add", ["name": "Paper", "color": ["model": "gray", "values": [0]]])
        try s.execute("swatches.use", ["swatch": "Paper", "target": "background"])
        #expect((0..<4).allSatisfy { abs(s.tools.background[$0] - 1) < 0.01 }, "\(s.tools.background)")
    }

    @Test func renameDeleteMoveAndGroups() throws {
        let s = Session()
        try s.execute("swatches.rename", ["swatch": "Black", "name": "Ink Black"])
        #expect(names(s).contains("Ink Black"))
        #expect(throws: EngineError.self, "duplicate") { try s.execute("swatches.rename", ["swatch": "Ink Black", "name": "White"]) }
        // Reorder within the group, then into another group.
        try s.execute("swatches.move", ["swatch": "White", "position": 0])
        #expect(groups(s)[0].items[0].name == "White")
        #expect(try s.execute("swatches.move", ["swatch": "White", "to": "Dark", "position": 1]) == ["group": "Dark", "position": 1])
        #expect(groups(s)[3].items[1].name == "White")
        // Out-of-range positions clamp.
        #expect(try s.execute("swatches.move", ["swatch": "White", "position": 999_999])["position"]?.intValue == 10)
        // New group from swatches, rename it, delete it keeping the swatches.
        #expect(try s.execute("swatches.newGroup", ["name": "Mine", "swatches": ["Red", "Blue"]]) == ["group": "Mine", "moved": 2])
        #expect(try s.execute("swatches.newGroup", ["name": "Mine"])["group"] == "Mine 1")
        try s.execute("swatches.renameGroup", ["group": "Mine", "name": "Favourites"])
        #expect(throws: EngineError.self) { try s.execute("swatches.renameGroup", ["group": "Favourites", "name": "Dark"]) }
        #expect(try s.execute("swatches.deleteGroup", ["group": "Favourites", "keepSwatches": true])["kept"]?.intValue == 2)
        #expect(groups(s)[3].items.contains { $0.name == "Red" }, "kept in the group above")
        try s.execute("swatches.deleteGroup", ["group": "Mine 1"])
        // Delete several by name, and one by index.
        #expect(try s.execute("swatches.delete", ["swatch": ["Red", "Blue", "Red"]])["deleted"]?.arrayValue?.count == 2)
        #expect(try s.execute("swatches.delete", ["index": 0])["deleted"] == ["Ink Black"])
        #expect(names(s).count == 37)
        // Reset restores the defaults; append adds them again with unique names.
        try s.execute("swatches.reset")
        #expect(names(s).count == 40)
        try s.execute("swatches.reset", ["append": true])
        #expect(names(s).count == 80)
        #expect(names(s).contains("Black 2"))
        #expect(groups(s)[4].name == "Grays 1")
    }

    @Test func changesPersistWithThePreferences() throws {
        let s = Session()
        try s.execute("swatches.add", ["name": "Keep me", "color": ["model": "lab", "values": [40, 12.5, -7.25]]])
        let saved = SC.libraryJSON(s)
        let t = Session()
        SC.loadLibrary(t, saved)
        #expect(groups(t) == groups(s))
        // A prefs file from before swatches existed keeps the defaults.
        let u = Session()
        SC.loadLibrary(u, nil)
        #expect(groups(u) == SC.builtin())
    }

    @Test func badParamsFailGracefully() throws {
        let s = Session()
        let before = groups(s)
        let cases: [(String, JSONValue)] = [
            ("swatches.add", ["color": "#12"]), ("swatches.add", ["color": ["model": "lab"]]), ("swatches.add", ["color": 5]),
            ("swatches.add", ["name": 7]), ("swatches.add", ["name": "   "]), ("swatches.add", ["group": []]), ("swatches.add", ["index": -1]),
            ("swatches.add", ["kind": "metallic"]), ("swatches.delete", [:]), ("swatches.delete", ["swatch": "Nope"]),
            ("swatches.delete", ["swatch": ["Red", 5]]), ("swatches.delete", ["swatch": ["Red", "Nope"]]), ("swatches.delete", ["index": 40]),
            ("swatches.delete", ["index": "0"]), ("swatches.delete", ["swatch": "Red", "group": "Grays"]), ("swatches.rename", ["swatch": "Red"]),
            ("swatches.rename", ["swatch": "Red", "name": ""]), ("swatches.rename", ["name": "x"]), ("swatches.move", ["swatch": "Red", "to": "Nowhere"]),
            ("swatches.move", ["swatch": "Red", "position": -3]), ("swatches.move", ["index": 999_999]), ("swatches.newGroup", ["swatches": "Red"]),
            ("swatches.newGroup", ["swatches": ["Nope"]]), ("swatches.newGroup", ["name": 3]), ("swatches.renameGroup", ["group": "Nope", "name": "x"]),
            ("swatches.renameGroup", ["group": "Grays"]), ("swatches.deleteGroup", [:]), ("swatches.deleteGroup", ["group": "Grays", "keepSwatches": "yes"]),
            ("swatches.use", ["swatch": "Red", "target": "middle"]), ("swatches.use", [:]), ("swatches.reset", ["append": 1]),
            ("swatches.import", [:]), ("swatches.import", ["path": "/nonexistent/x.aco"]), ("swatches.import", ["data": "%%%"]),
            ("swatches.import", ["data": .string(Base64.encode(Array("junk junk".utf8)))]),
            ("swatches.import", ["data": .string(Base64.encode(Array("ASEF".utf8) + [0, 1, 0, 0, 0xff, 0xff, 0xff, 0xff]))]),
            ("swatches.import", ["data": .string(Base64.encode([0, 1, 0xff, 0xff]))]), ("swatches.import", ["data": .string(Base64.encode([0, 1, 0, 0]))]),
            ("swatches.import", ["data": .string(Base64.encode([0, 1, 0, 0])), "format": "gpl"]),
            ("swatches.import", ["data": .string(Base64.encode([0, 1, 0, 0])), "mode": "merge"]),
            ("swatches.export", ["format": "pdf"]), ("swatches.export", ["group": "Nope"]), ("swatches.export", ["swatches": ["Nope"]]),
            ("swatches.export", ["swatches": "Red"]),
        ]
        for (id, p) in cases { #expect(throws: EngineError.self, "\(id) \(p)") { try s.execute(id, p) } }
        // An unwritable path (its "folder" is a file) is an error.
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("pc-swatch-file-\(UUID().uuidString)")
        try Data("x".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(throws: (any Error).self) { try s.execute("swatches.export", ["path": .string(file.appendingPathComponent("x.aco").path)]) }
        #expect(groups(s) == before, "failed commands change nothing")
        // Empty library: the swatch commands are disabled, not crashing.
        try s.execute("swatches.delete", ["swatch": .strings(names(s))])
        for g in ["Grays", "Pastel", "Pure", "Dark"] { try s.execute("swatches.deleteGroup", ["group": .string(g)]) }
        for id in ["swatches.delete", "swatches.rename", "swatches.move", "swatches.use", "swatches.export", "swatches.renameGroup", "swatches.deleteGroup"] {
            #expect(throws: EngineError.self, "\(id)") { try s.execute(id, ["swatch": "Red", "group": "Grays", "name": "x"]) }
        }
        // Adding to an empty library creates a group.
        #expect(try s.execute("swatches.add")["group"] == "Swatches")
    }

    func exportBytes(_ s: Session, _ p: JSONValue) throws -> [UInt8] {
        let r = try s.execute("swatches.export", p)
        let data = try #require(r["data"]?.stringValue)
        return try #require(Base64.decode(data))
    }

    @Test func acoRoundTripKeeps16BitValuesAndBooks() throws {
        let swatches = [
            PSDAco.Swatch(name: "R", color: .rgb(65535, 12345, 1)),
            PSDAco.Swatch(name: "H", color: .hsb(40000, 30000, 65535)),
            PSDAco.Swatch(name: "C", color: .cmyk(65535, 1, 32768, 7)),
            PSDAco.Swatch(name: "L", color: .lab(l: 5321, a: -12800, b: 12700)),
            PSDAco.Swatch(name: "G", color: .gray(1234)),
            PSDAco.Swatch(name: "Book", color: .other(space: 3, values: [9, 8, 7, 6])),
        ]
        let file = [UInt8](try PSDAco.write(swatches))
        let s = Session()
        let r = try s.execute("swatches.import", ["data": .string(Base64.encode(file)), "group": "Pro", "mode": "replace"])
        #expect(r["format"]?.stringValue == "aco" && r["count"]?.intValue == 6)
        #expect(r["warnings"]?.arrayValue?.count == 1, "the colour book is reported")
        #expect(groups(s).count == 1)
        #expect(groups(s)[0].items[3].color == .lab(SIMD3(53.21, -128, 127)))
        #expect(groups(s)[0].items[4].color.model == "gray")
        #expect(try exportBytes(s, ["format": "aco"]) == file, "byte-identical .aco")
        // On disk too, with the group taken from the file name.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pc-swatch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("Brand Colors.aco")
        try Data(file).write(to: path)
        let r2 = try s.execute("swatches.import", ["path": .string(path.path)])
        #expect(r2["groups"] == .strings(["Brand Colors"]))
        #expect(names(s).filter { $0.hasPrefix("R") }.count == 2, "imported names are made unique")
        let out = dir.appendingPathComponent("out.ase")
        let r3 = try s.execute("swatches.export", ["path": .string(out.path), "group": "Pro"])
        #expect(r3["format"]?.stringValue == "ase" && r3["count"]?.intValue == 5, "the book can't go to .ase")
        #expect(try Data(contentsOf: out).starts(with: Array("ASEF".utf8)))
    }

    @Test func aseRoundTripKeepsGroupsFloatsAndKinds() throws {
        let src = PSDAse.File(entries: [
            .swatch(PSDAse.Swatch(name: "Loose", color: .rgb(0.1, 0.2, 0.3), kind: .process)),
            .group(name: "Brand", swatches: [
                PSDAse.Swatch(name: "Spot ink", color: .cmyk(0, 0.85, 1, 0.05), kind: .spot),
                PSDAse.Swatch(name: "Global lab", color: .lab(0.5, 20, -30), kind: .global),
                PSDAse.Swatch(name: "Gray", color: .gray(0.25), kind: .process),
                PSDAse.Swatch(name: "Weird", color: .other(model: "XYZ ", data: [UInt8](repeating: 0, count: 12)), kind: .process),
            ]),
        ])
        let bytes = [UInt8](try PSDAse.write(src))
        let s = Session()
        let r = try s.execute("swatches.import", ["data": .string(Base64.encode(bytes)), "group": "Exchange"])
        #expect(r["groups"] == .strings(["Exchange", "Brand"]))
        #expect(r["count"] == 4)
        #expect(r["warnings"]?.arrayValue?.count == 1, "the unknown model is reported")
        let brand = try #require(groups(s).first { $0.name == "Brand" })
        #expect(brand.items[0].kind == .spot)
        #expect(brand.items[1].color == .lab(SIMD3(50, 20, -30)))
        #expect(brand.items[2].color == .gray(0.75))
        // Export both groups and read them back.
        let out = try exportBytes(s, ["format": "ase", "swatches": ["Loose", "Spot ink", "Global lab", "Gray"]])
        let back = try PSDAse.parse(Data(out))
        let flat: [PSDAse.Swatch] = back.entries.flatMap { e -> [PSDAse.Swatch] in
            switch e {
            case .group(_, let sw): sw
            case .swatch(let sw): [sw]
            }
        }
        try #require(flat.count == 4)
        #expect(flat[0].color == .rgb(0.1, 0.2, 0.3))
        #expect(flat[1].color == .cmyk(0, 0.85, 1, 0.05))
        #expect(flat[1].kind == .spot)
        #expect(flat[2].kind == .global)
        guard case let .lab(l0, l1, l2) = flat[2].color, case let .gray(g) = flat[3].color else {
            Issue.record("models")
            return
        }
        #expect(abs(l0 - 0.5) < 1e-6 && l1 == 20 && l2 == -30)
        #expect(abs(g - 0.25) < 1e-6)
        // HSB swatches become RGB in .ase.
        try s.execute("swatches.add", ["name": "Hue", "color": ["model": "hsb", "values": [120, 100, 100]]])
        let out2 = try exportBytes(s, ["format": "ase", "swatches": ["Hue"]])
        let back2 = try PSDAse.parse(Data(out2))
        #expect(back2.entries == [.group(name: "Grays", swatches: [PSDAse.Swatch(name: "Hue", color: .rgb(0, 1, 0), kind: .process)])])
    }

    @Test func libraryLimits() throws {
        let s = Session()
        let one = Array(repeating: PSDAco.Swatch(name: "x", color: .gray(0)), count: 60_000)
        let file = Base64.encode([UInt8](try PSDAco.write(one)))
        try s.execute("swatches.import", ["data": .string(file), "mode": "replace"])
        #expect(throws: EngineError.self, "over the library limit") { try s.execute("swatches.import", ["data": .string(file)]) }
        #expect(names(s).count == 60_000)
    }

    @Test func capLibraryTrimsAHandEditedLibrary() {
        var g = [SC.Group(name: String(repeating: "n", count: 1000), items: Array(repeating: SC.Swatch(name: "a", color: .gray(0)), count: SC.maxSwatches + 5))]
        SC.capLibrary(&g)
        #expect(SC.total(g) == SC.maxSwatches)
        #expect(g[0].name.count == SC.maxName)
    }

    // MARK: presets/swatches.rs

    @Test func defaultLibraryHasTheFortyColours() {
        let b = SC.builtin()
        #expect(SC.total(b) == 40)
        #expect(Set(b.flatMap { $0.items.map(\.name) }).count == 40, "names are unique")
        #expect(b[2].items[0].color == .rgb(SIMD3(230 / 255, 40 / 255, 40 / 255)))
    }

    @Test func conversionsGoThroughTheCMS() {
        let c = SC.Conv(nil)
        func near(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ tol: Float) -> Bool { (0..<3).allSatisfy { abs(a[$0] - b[$0]) <= tol } }
        #expect(c.rgb(.rgb(SIMD3(0.1, 0.2, 0.3))) == SIMD3(0.1, 0.2, 0.3))
        #expect(near(c.rgb(.hsb(SIMD3(120, 1, 1))), SIMD3(0, 1, 0), 1e-6))
        // Lab white and black, gray (no ink = white), paper-white CMYK.
        #expect(near(c.rgb(.lab(SIMD3(100, 0, 0))), SIMD3(repeating: 1), 0.01))
        #expect(near(c.rgb(.lab(SIMD3(0, 0, 0))), SIMD3(repeating: 0), 0.01))
        #expect(near(c.rgb(.gray(0)), SIMD3(repeating: 1), 0.01))
        #expect(near(c.rgb(.gray(1)), SIMD3(repeating: 0), 0.01))
        #expect(near(c.rgb(.cmyk(.zero)), SIMD3(repeating: 1), 0.02))
        // Full cyan reads as a blue-green, not as naive (0, 1, 1).
        let cy = c.rgb(.cmyk(SIMD4(1, 0, 0, 0)))
        #expect(cy.x < 0.3 && cy.z > cy.x && cy.y > cy.x, "\(cy)")
        let red = c.rgb(.lab(SIMD3(54, 80, 67)))
        #expect(red.x > 0.9 && red.y < 0.2, "\(red)")
        // Out-of-range and non-finite stored values never escape 0…1.
        for col: SC.SwatchColor in [.rgb(SIMD3(.nan, 9, -3)), .hsb(SIMD3(.infinity, 2, -1)), .lab(SIMD3(500, .nan, -999))] {
            let v = c.rgb(col)
            #expect((0..<3).allSatisfy { v[$0] >= 0 && v[$0] <= 1 }, "\(col)")
        }
        #expect(c.rgb(.book(space: 3, values: [0, 0, 0, 0])) == SIMD3(repeating: 0.5))
    }

    @Test func aWideGamutWorkingSpaceChangesCMYKButNotRGB() throws {
        let s = Session()
        try s.execute("prefs.set", ["path": "colorSettings.workingRgb", "value": "display-p3"])
        let p3 = SC.Conv(s), srgb = SC.Conv(nil)
        let cmyk = SC.SwatchColor.cmyk(SIMD4(1, 0, 0, 0))
        #expect(p3.rgb(cmyk) != srgb.rgb(cmyk))
        #expect(p3.rgb(.rgb(SIMD3(0.2, 0.4, 0.6))) == SIMD3(0.2, 0.4, 0.6))
    }

    @Test func colourParams() throws {
        #expect(try SC.SwatchColor.fromParam("#ff0000") == .rgb(SIMD3(1, 0, 0)))
        #expect(try SC.SwatchColor.fromParam(["model": "cmyk", "values": [100, 0, 50, 0]]) == .cmyk(SIMD4(1, 0, 0.5, 0)))
        #expect(try SC.SwatchColor.fromParam(["model": "gray", "values": [25]]) == .gray(0.25))
        #expect(try SC.SwatchColor.fromParam(["model": "lab", "values": [50, -20, 30]]).displayValues == [50, -20, 30])
        let bad: [JSONValue] = [
            "#ff00", "red", 5, [:], ["model": "rgb"], ["model": "rgb", "values": [1, 2]], ["model": "rgb", "values": ["a", 2, 3]],
            ["model": "xyz", "values": [1, 2, 3]], ["model": "gray", "values": []],
        ]
        for v in bad { #expect(throws: SC.ColorError.self, "\(v)") { try SC.SwatchColor.fromParam(v) } }
    }

    @Test func serdeRoundTrip() {
        let sw = [
            SC.Swatch(name: "a", color: .lab(SIMD3(50, -1.5, 2.25)), kind: .spot),
            SC.Swatch(name: "b", color: .book(space: 3, values: [1, 2, 3, 4])),
            SC.Swatch(name: "c", color: .gray(0.5)),
        ]
        #expect(sw[2].serde == ["name": "c", "color": ["model": "gray", "values": 0.5]])
        let s = Session()
        SC.loadLibrary(s, [["name": "G", "items": .array(sw.map(\.serde))]])
        #expect(groups(s) == [SC.Group(name: "G", items: sw)])
    }
}
