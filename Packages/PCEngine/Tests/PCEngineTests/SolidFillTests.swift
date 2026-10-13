// Port of photocraft-engine (crates/engine/src/solid_fill_cmds.rs tests), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Deviations: `layer.vectorMask.revealAll` isn't in this package yet (the edit test keeps a layer
// mask only), and CMYK / Lab documents are made with `file.new {"mode"}` instead of Image › Mode
// (image_cmds) — the fill layer is created in the converted mode either way.

import Foundation
import PCDocument
@testable import PCEngine
import PCFoundation
import Testing

@Suite struct SolidFillTests {
    typealias T = StyleTestSupport
    let set = SolidFillCommands.set

    func solid(_ s: Session, _ id: LayerId? = nil) -> PCColor? {
        guard let d = s.active, let l = d.doc.layer(id ?? d.activeLayer ?? LayerId(0)), case .fill(.solid(let c)) = l.content else { return nil }
        return c
    }

    func entries(_ s: Session) -> Int { s.active?.history.entries.count ?? -1 }

    @Test func editPreservesLayerAndMasksAtAllDepthsAndUndoRedo() throws {
        for depth in [8, 16, 32] {
            let s = try T.session(32, 24, extra: ["depth": .int(depth)])
            let id = LayerId(try #require(try s.execute("layer.newFillLayer.solidColor", ["color": "#12345680"])["layer"]?.uint64Value))
            try s.execute("layer.layerMask.revealAll")
            let before = try #require(s.active?.doc)
            let count = entries(s)
            let color = PCColor(mode: .lab, c: SIMD4(0.512345, 0.48, 0.6, 0), alpha: 0.345678)
            try s.execute(set, ["layer": .id(id), "color": .encoded(color)])
            var expected = before
            expected.updateLayer(id) { $0.content = .fill(.solid(color)) }
            #expect(s.active?.doc == expected)
            #expect(entries(s) == count + 1)
            try s.execute("edit.undo")
            #expect(s.active?.doc == before)
            try s.execute("edit.redo")
            #expect(solid(s, id) == color)
            let count2 = entries(s)
            try s.execute(set, ["color": .encoded(color)])
            #expect(entries(s) == count2, "unchanged colour is not a history step")
            try s.execute(set, ["color": "#abcdef"])
            #expect(solid(s, id)?.alpha == color.alpha)
        }
    }

    @Test func badParamsWrongLayerAndStaleDocumentLeaveHistoryUntouched() throws {
        let s = Session()
        #expect(throws: EngineError.self) { try s.execute(set, ["color": "#ffffff"]) }
        try s.execute("file.new", ["width": 2, "height": 2])
        let pixels = try #require(try s.execute("layer.new.layer")["layer"]?.uint64Value)
        try s.execute("layer.newFillLayer.solidColor")
        let before = try #require(s.active?.doc)
        let count = entries(s)
        let bad: [JSONValue] = [
            [:], .null, ["color": true], ["color": [1, "bad", 0]], ["color": [1, 0, 0, 2]], ["color": "#💥💥"], ["layer": "bad", "color": "#ffffff"],
            ["layer": .number(Double(pixels)), "color": "#ffffff"], ["layer": .number(Double(UInt64.max)), "color": "#ffffff"],
            ["document": .number(Double(UInt64.max)), "color": "#ffffff"],
        ]
        for p in bad {
            #expect(throws: EngineError.self, "\(p)") { try s.execute(set, p) }
            #expect(s.active?.doc == before)
            #expect(entries(s) == count)
        }
    }

    @Test func editsRespectLayerAndTransparencyLocks() throws {
        let s = try T.session(2, 2)
        try s.execute("layer.newFillLayer.solidColor", ["color": "#12345680"])
        for locks: JSONValue in [["all": true], ["all": false, "pixels": true], ["pixels": false, "transparency": true]] {
            try s.execute("layer.setProps", ["locks": locks])
            let before = try #require(s.active?.doc)
            #expect(throws: EngineError.self) { try s.execute(set, ["color": "#abcdef00"]) }
            #expect(s.active?.doc == before)
        }
        try s.execute(set, ["color": "#abcdef"])
    }

    @Test func rgbPickerInputsFollowDocumentModeAndPreserveAlpha() throws {
        for mode: ColorMode in [.rgb, .cmyk, .lab] {
            let s = try T.session(8, 8, extra: ["depth": 16, "mode": .string(mode == .rgb ? "rgb" : mode == .cmyk ? "cmyk" : "lab")])
            let id = LayerId(try #require(try s.execute("layer.newFillLayer.solidColor", ["color": "#12345680"])["layer"]?.uint64Value))
            let original = try #require(solid(s, id))
            #expect(s.active?.doc.mode == mode)
            let count = entries(s)
            let cases: [(JSONValue, PCColor)] = [
                ("#336699", .rgb(51 / 255, 102 / 255, 153 / 255, original.alpha)), ([0.25, 0.5, 0.75], .rgb(0.25, 0.5, 0.75, original.alpha)),
            ]
            for (value, rgb) in cases {
                let expected = rgb.converted(to: mode)
                let result = try s.execute(set, ["layer": .id(id), "color": value])
                #expect(try result["color"]?.decode(as: PCColor.self) == expected)
                #expect(solid(s, id) == expected)
                #expect(solid(s, id)?.alpha == original.alpha)
            }
            #expect(entries(s) == count + 2)
            // Reapplying the same RGB array is a no-op, including after mode conversion.
            let beforeNoop = try #require(s.active?.doc)
            try s.execute(set, ["layer": .id(id), "color": [0.25, 0.5, 0.75]])
            #expect(s.active?.doc == beforeNoop)
            #expect(entries(s) == count + 2)
            let expected = PCColor.rgb(0.25, 0.5, 0.75, 0.25).converted(to: mode)
            try s.execute(set, ["layer": .id(id), "color": [0.25, 0.5, 0.75, 0.25]])
            #expect(solid(s, id) == expected)
            try s.execute("edit.undo")
            #expect(solid(s, id) == PCColor.rgb(0.25, 0.5, 0.75, original.alpha).converted(to: mode))
            try s.execute("edit.redo")
            #expect(solid(s, id) == expected)
        }
    }

    @Test func storedColourRemainsExactWithoutRGBConversionOrExtraHistory() throws {
        let s = try T.session(4, 4, extra: ["mode": "cmyk"])
        try s.execute("layer.newFillLayer.solidColor")
        let imported = PCColor(mode: .lab, c: SIMD4(0.5123457, 0.4987654, 0.5678912, 0), alpha: 0.3456789)
        try s.execute(set, ["color": .encoded(imported)])
        let before = try #require(s.active?.doc)
        let count = entries(s)
        let result = try s.execute(set, ["color": .encoded(imported)])
        #expect(try result["color"]?.decode(as: PCColor.self) == imported)
        #expect(s.active?.doc == before)
        #expect(entries(s) == count)
    }

    @Test func invalidRGBComponentsLeaveDocumentAndHistoryUnchanged() throws {
        let s = try T.session(4, 4)
        try s.execute("layer.newFillLayer.solidColor")
        let before = try #require(s.active?.doc)
        let count = entries(s)
        let bad: [JSONValue] = [
            [5.0, 0.0, 0.0], [-0.01, 0.0, 0.0], [1.00000000000001, 0.0, 0.0], [0.0, 0.0, 0.0, -0.1], [0.0, 0.0, 0.0, 1.1], [1e300, 0.0, 0.0],
            ["NaN", 0.0, 0.0], ["Infinity", 0.0, 0.0], [.null, 0.0, 0.0], [0.0, 0.0], [0.0, 0.0, 0.0, 0.0, 0.0],
        ]
        for color in bad {
            do {
                try s.execute(set, ["color": color])
                Issue.record("\(color) should fail")
            } catch let e as EngineError {
                if case .badParams = e {} else { Issue.record("\(color): \(e)") }
            }
            #expect(s.active?.doc == before)
            #expect(entries(s) == count)
        }
        // Stored non-RGB colours are not subject to the RGB picker component limits.
        let wide = PCColor(mode: .lab, c: SIMD4(1.1, -0.1, 0.6, 0), alpha: 0.75)
        try s.execute(set, ["color": .encoded(wide)])
        #expect(solid(s) == wide)
    }
}
