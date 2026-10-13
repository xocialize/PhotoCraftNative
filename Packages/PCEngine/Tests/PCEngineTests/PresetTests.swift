// Port of photocraft-engine (crates/engine/src/presets/tests.rs, minus the clone-source tests), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Deviations: `paint.gradient` (paint_cmds) isn't in this package, so the tests that painted with
// the Gradient tool check the stops it paints with (`PresetCommands.toolStops`, sampled where the
// stroke's pixels would be) instead of the painted pixels; `tools.setBrush` (brush_cmds) is a small
// test double that merges brush JSON; Define Custom Shape (edit_menu_cmds) is seeded through
// `PresetCommands.CustomShapesKey`; preferences persistence goes through
// `PresetCommands.persistedJSON` / `loadPersisted`.

import Foundation
import PCDocument
@testable import PCEngine
import PCFoundation
import PCPaint
import Testing

@Suite struct PresetTests {
    typealias T = StyleTestSupport
    typealias P = PresetCommands

    func session(_ depth: Int = 8) throws -> Session { try T.session(64, 48, extra: ["depth": .int(depth)]) }

    /// A session whose registry has a `tools.setBrush` double (brush settings deep-merged from JSON).
    static func brushSession() -> Session {
        var r = CommandRegistry.standard()
        @Sendable func merge(_ a: JSONValue, _ b: JSONValue) -> JSONValue {
            guard case .object(var o) = a, case .object(let p) = b else { return b }
            for (k, v) in p { o[k] = o[k].map { merge($0, v) } ?? v }
            return .object(o)
        }
        r.add(CommandSpec("tools.setBrush", "Set Brush", module: "test") { s, p in
            var cur = JSONValue.encoded(s.tools.brush)
            if let b = p["brush"] { cur = merge(cur, b) }
            cur = merge(cur, p.removing("brush"))
            s.tools.brush = try cur.decode(as: BrushSettings.self)
            return .null
        })
        return Session(registry: r)
    }

    /// The Gradient tool's stops for `p`, sampled at `t`.
    func tool(_ s: Session, _ p: JSONValue = [:], at t: Float) throws -> SIMD4<Float> {
        let stops = try #require(try P.toolStops(s, p))
        return try #require(P.sample(stops, t, P.lerp4))
    }

    func listGroups(_ s: Session, _ cmd: String) throws -> [JSONValue] { try s.execute(cmd)["groups"]?.arrayValue ?? [] }

    // MARK: Styles

    @Test func stylePresetNewFromAnExplicitEffectList() throws {
        let s = try T.session(16, 16)
        try s.execute("layer.new.layer")
        // The Layer Style dialog's "New Style…" saves its pending state, not the layer.
        let r = try s.execute("style.presets.new", ["name": "Pending", "effects": [["stroke", ["size": 6, "color": "#123456"]]], "blend": "Multiply",
                                                    "fillOpacity": 40])
        #expect(r["name"] == "Pending")
        try s.execute("layer.new.layer")
        try s.execute("style.presets.apply", ["preset": "Pending"])
        let l = try #require(s.active.flatMap { $0.doc.layer($0.activeLayer!) })
        #expect(l.effects.items.count == 1)
        if case .stroke(let st)? = l.effects.items.first { #expect(st.size == 6) } else { Issue.record("no stroke") }
        #expect(l.blend == .multiply)
        #expect(abs(l.fillOpacity - 0.4) < 1e-6)
        // Malformed lists are graceful errors.
        #expect(throws: EngineError.self) { try s.execute("style.presets.new", ["effects": [["nope", [:]]]]) }
        #expect(throws: EngineError.self) { try s.execute("style.presets.new", ["effects": ["stroke"]]) }
    }

    @Test func stylesApplyToSelectedLayersAndNewFromLayer() throws {
        let s = try session(16)
        let a = LayerId(try #require(try s.execute("layer.new.layer")["layer"]?.uint64Value))
        let b = LayerId(try #require(try s.execute("layer.new.layer")["layer"]?.uint64Value))
        try s.execute("layer.select", ["layer": .id(a)])
        try s.execute("layer.select", ["layer": .id(b), "mode": "add"])
        let r = try s.execute("style.presets.apply", ["preset": "Gold"])
        #expect(r["layers"]?.arrayValue?.count == 2)
        func fx(_ id: LayerId) -> Int { s.active?.doc.layer(id)?.effects.items.count ?? -1 }
        #expect(fx(a) == 3 && fx(b) == 3)
        // ⇧-click adds; plain apply replaces; Default Style clears.
        try s.execute("style.presets.apply", ["preset": "Black Stroke", "add": true, "layer": .id(a)])
        #expect(fx(a) == 4)
        try s.execute("style.presets.apply", ["preset": "Hollow", "layer": .id(b)])
        let lb = try #require(s.active?.doc.layer(b))
        #expect(lb.effects.items.count == 1 && lb.fillOpacity == 0)
        try s.execute("style.presets.apply", ["preset": "Default Style (None)", "layer": .id(b)])
        #expect(s.active?.doc.layer(b)?.fillOpacity == 1)
        // One undo step per apply.
        try s.execute("edit.undo")
        #expect(fx(b) == 1)
        // New Style from the layer, applied elsewhere.
        try s.execute("layer.select", ["layer": .id(a)])
        try s.execute("style.presets.new", ["name": "From A", "group": "Mine"])
        try s.execute("style.presets.apply", ["preset": "From A", "layer": .id(b)])
        #expect(fx(b) == 4)
        #expect(throws: EngineError.self) { try s.execute("style.presets.apply", ["preset": "nope"]) }
        // Thumbnails render the effect around the swatch.
        let st = try #require(P.state(s).styles[0].items.first { $0.name == "Outer Glow" })
        let px = try P.styleThumbnail(s, st, 48)
        #expect(px.count == 48 * 48 * 4)
        #expect(px[(4 * 48 + 24) * 4 + 3] == 0 || px[(7 * 48 + 24) * 4 + 3] > 0, "glow reaches outside the square")
        #expect(px[(24 * 48 + 24) * 4 + 3] == 255)
    }

    @Test func stylesWithPatternOverlayCopyThePattern() throws {
        let s = try session()
        try s.execute("layer.new.layer")
        let id = try #require(s.active?.activeLayer)
        let fx = try #require(LayerStyleCommands.effectFromParams("patternOverlay", ["pattern": "Bricks"]))
        s.state[P.Key.self].styles[0].items.append(P.StylePreset(name: "Bricky", effects: [fx]))
        try s.execute("style.presets.apply", ["preset": "Bricky", "layer": .id(id)])
        #expect(s.active?.doc.patterns.contains { $0.name == "Bricks" } == true)
    }

    // MARK: Gradients

    @Test func gradientBuiltinsAndListing() throws {
        let s = Session()
        let v = try s.execute("gradient.presets.list")
        let groups = v["groups"]?.arrayValue ?? []
        let names = groups.compactMap { $0["name"]?.stringValue }
        #expect(names.first == "Basics")
        #expect(names.contains("Blues") && names.contains("Grays"))
        #expect(v["current"]?["name"] == "Foreground to Background")
        #expect(groups[0]["presets"]?[1]?["transparency"]?[1] == [1.0, 0.0])
    }

    @Test func rainbowGradientPresets() throws {
        let s = try session()
        let v = try s.execute("gradient.presets.list")
        let group = try #require(v["groups"]?.arrayValue?.first { $0["name"] == "Rainbows" })
        let presets = group["presets"]?.arrayValue ?? []
        #expect(presets.compactMap { $0["name"]?.stringValue } == ["Rainbow", "Pastel Rainbow", "Neon Rainbow", "Oil Slick", "Rainbow Fade"])
        // The three hue ramps share the same 13 evenly spaced hues.
        for p in presets.prefix(3) {
            let stops = p["stops"]?.arrayValue ?? []
            #expect(stops.count == 13)
            #expect(stops.first?[0] == 0.0 && stops.last?[0] == 1.0)
        }
        #expect(presets[3]["stops"]?.arrayValue?.count == 11, "oil slick")
        #expect(presets[4]["transparency"] == [[0.0, 0.0], [0.125, 100.0], [0.875, 100.0], [1.0, 0.0]])
        // Rainbow Fade paints opaque across the middle and transparent at both ends.
        try s.execute("gradient.presets.select", ["preset": "Rainbow Fade"])
        #expect(try tool(s, at: 0).w < 0.1)
        #expect(try tool(s, at: 1).w < 0.1)
        #expect(try tool(s, at: 0.5).w > 0.95)
    }

    @Test func gradientToolUsesSelectedPreset() throws {
        let s = try session()
        // Default (Foreground to Background): black → white.
        #expect(try tool(s, at: 0).x < 0.02 && tool(s, at: 1).x > 0.98)
        try s.execute("gradient.presets.select", ["preset": "Red 01"])
        let left = try tool(s, at: 0)
        // Red 01 starts at #7f0000.
        #expect(abs(left.x - 127 / 255) < 0.02 && left.y < 0.01, "\(left)")
        // Explicit stops and a named preset override the selection.
        #expect(try tool(s, ["stops": [[0, "#00ff00"], [1, "#0000ff"]]], at: 0).y > 0.98)
        #expect(try tool(s, ["gradient": "Black, White"], at: 1).x > 0.98)
        #expect(try P.toolStops(s, ["colors": ["#000000", "#ffffff"]]) == nil, "the legacy colours form is paint.gradient's own")
    }

    @Test func foregroundToTransparentPaintsAlpha() throws {
        let s = try session()
        try s.execute("gradient.presets.select", ["preset": "Foreground to Transparent"])
        #expect(try tool(s, at: 0).w > 0.95)
        #expect(try tool(s, at: 1).w < 0.05)
        #expect(abs(try tool(s, at: 0.5).w - 0.5) < 0.05)
    }

    /// `gradient.presets.stop` edits the Gradient tool's current gradient in place.
    @Test func presetStopEditsTheCurrentGradient() throws {
        let s = try session()
        // A new stop mid-way samples the ramp there (black → white: mid gray).
        let v = try s.execute("gradient.presets.stop", ["action": "add", "location": 0.5])
        let stops = v["current"]?["stops"]?.arrayValue ?? []
        #expect(stops.count == 3)
        #expect(stops.count > 1 && stops[1] == [0.5, "#808080"], "sorted by location, the ramp colour at 0.5")
        try s.execute("gradient.presets.stop", ["action": "color", "index": 1, "color": "#ff0000"])
        let mid = try tool(s, at: 0.5)
        #expect(mid.x > 0.9 && mid.y < 0.1, "\(mid)")
        // A "foreground" stop stays live.
        try s.execute("gradient.presets.stop", ["action": "color", "index": 0, "color": "foreground"])
        try s.execute("tools.setColors", ["foreground": "#0000ff"])
        let start = try tool(s, at: 0)
        #expect(start.z > 0.9 && start.x < 0.1, "\(start)")
        // Opacity stops materialize the two opaque ends on first edit.
        let o = try s.execute("gradient.presets.stop", ["action": "add", "kind": "opacity", "location": 0.5, "opacity": 40])
        #expect(o["current"]?["transparency"] == [[0.0, 100.0], [0.5, 40.0], [1.0, 100.0]])
        #expect(abs(try tool(s, at: 0.5).w - 0.4) < 0.05)
        // Guard rails: in-range indexes, known actions, two stops minimum, no midpoints.
        #expect(throws: EngineError.self) { try s.execute("gradient.presets.stop", ["action": "move", "index": 99, "location": 0.5]) }
        #expect(throws: EngineError.self) { try s.execute("gradient.presets.stop", ["action": "explode"]) }
        try s.execute("gradient.presets.stop", ["action": "delete", "index": 0])
        #expect(throws: EngineError.self, "a gradient keeps at least 2 colour stops") {
            try s.execute("gradient.presets.stop", ["action": "delete", "index": 0])
        }
        #expect(throws: EngineError.self) { try s.execute("gradient.presets.stop", ["action": "midpoint", "index": 0, "location": 0.4]) }
    }

    @Test func presetStopSurvivesAComplexManyStopRamp() throws {
        let s = try session()
        try s.execute("gradient.presets.select", ["stops": [[0.0, "#000000"], [1.0, "#ffffff"]]])
        for (i, c) in ["#ff0000", "#00ff00", "#0000ff", "#ffff00", "#ff00ff"].enumerated() {
            try s.execute("gradient.presets.stop", ["action": "add", "location": .number(Double(i + 1) / 6), "color": .string(c)])
        }
        #expect(try s.execute("gradient.presets.list")["current"]?["stops"]?.arrayValue?.count == 7)
        // Drag the yellow stop (index 4, at 4/6) past the magenta one (at 5/6).
        try s.execute("gradient.presets.stop", ["action": "move", "index": 4, "location": 0.95])
        let stops = try s.execute("gradient.presets.list")["current"]?["stops"]?.arrayValue ?? []
        let locs = stops.compactMap { $0[0]?.doubleValue }
        #expect(locs == locs.sorted(), "stops stay sorted after a crossing move: \(stops)")
        #expect(stops.last == [1.0, "#ffffff"])
        // The paint follows: near the moved stop the stroke is the stop's yellow.
        let px = try tool(s, at: 60 / 63)
        #expect(px.x > 0.95 && px.y > 0.95 && px.z < 0.3, "\(px)")
        for _ in 0..<5 { try s.execute("gradient.presets.stop", ["action": "delete", "index": 1]) }
        let trimmed = try s.execute("gradient.presets.list")["current"]?["stops"]
        #expect(trimmed == [[0.0, "#000000"], [1.0, "#ffffff"]])
    }

    @Test func presetStopOpacityHoleMovesAndNormalizes() throws {
        let s = try session()
        try s.execute("gradient.presets.stop", ["action": "add", "kind": "opacity", "location": 0.5, "opacity": 0])
        #expect(try tool(s, at: 0).w > 0.95)
        #expect(try tool(s, at: 0.5).w < 0.05)
        #expect(try tool(s, at: 1).w > 0.95)
        // The hole follows the moved stop (index 1 is the 0 % stop between the opaque ends).
        try s.execute("gradient.presets.stop", ["action": "move", "kind": "opacity", "index": 1, "location": 0.25])
        #expect(try tool(s, at: 20 / 63).w < 0.15)
        let far = try tool(s, at: 48 / 63).w
        #expect(far > 0.55 && far < 0.85, "\(far)")
        // Deleting it returns the gradient to fully opaque, stored as no opacity stops at all.
        try s.execute("gradient.presets.stop", ["action": "delete", "kind": "opacity", "index": 1])
        #expect(try s.execute("gradient.presets.list")["current"]?["transparency"] == [])
    }

    @Test func editedPresetSavesAndRoundtrips() throws {
        let s = try session()
        try s.execute("gradient.presets.stop", ["action": "add", "location": 0.5, "color": "#ff0000"])
        try s.execute("gradient.presets.new", ["name": "My Gradient"])
        try s.execute("gradient.presets.select", ["preset": "Red 01"])
        try s.execute("gradient.presets.select", ["preset": "My Gradient"])
        let px = try tool(s, at: 0.5)
        #expect(px.x > 0.9 && px.y < 0.1, "\(px)")
    }

    /// Issue #465: explicit `transparency` stops apply with a `gradient` preset, explicit `stops`
    /// and the current gradient alike.
    @Test func toolStopsHonourExplicitTransparencyStops() throws {
        let transparency: JSONValue = [[0, 65], [1, 0]]
        let extras: [JSONValue] = [
            ["gradient": "Black, White"], ["gradient": "Foreground to Transparent", "transparency": [[0, 65], [0.5, 65], [1, 0]]],
            ["stops": [[0, "#07111d"], [1, "#07111d"]]], [:],
        ]
        for extra in extras {
            let s = Session()
            let p = JSONValue.object(["transparency": transparency]).merging(extra)
            #expect(abs(try tool(s, p, at: 0).w - 0.65) < 0.03, "\(extra)")
            #expect(try tool(s, p, at: 1).w < 0.03, "\(extra)")
        }
        let s = Session()
        for bad: JSONValue in ["65", [[0]], [[0, "a"]]] {
            #expect(throws: EngineError.self) { try P.toolStops(s, ["transparency": bad]) }
        }
    }

    @Test func gradientApplyCreatesFillLayerAndSelectRecoloursIt() throws {
        let s = try session()
        let r = try s.execute("gradient.presets.apply", ["preset": "Blue 01", "angle": 0])
        let id = LayerId(try #require(r["layer"]?.uint64Value))
        func gradient() throws -> GradientFill {
            guard case .fill(.gradient(let g))? = s.active?.doc.layer(id)?.content else { throw EngineError.other("not a gradient fill") }
            return g
        }
        #expect(try gradient().angle == 0)
        #expect(abs(try gradient().stops[0].color.c.z - Float(0x91) / 255) < 1e-3)
        // Clicking another preset with the fill layer selected changes it (one undo step).
        let r2 = try s.execute("gradient.presets.select", ["preset": "Green 01"])
        #expect(r2["layer"] == .id(id))
        #expect(try gradient().stops[0].color.c.y > 0.25)
        try s.execute("edit.undo")
        #expect(abs(try gradient().stops[0].color.c.z - Float(0x91) / 255) < 1e-3)
    }

    @Test func gradientNewRenameMoveDeleteGroups() throws {
        let s = Session()
        let rev = P.state(s).rev
        try s.execute("gradient.presets.select", ["stops": [[0, "#112233"], [0.5, "foreground"], [1, "#ffffff"]], "transparency": [[0, 100], [1, 50]]])
        let r = try s.execute("gradient.presets.new", ["name": "Mine", "group": "My Gradients"])
        #expect(r["group"] == "My Gradients")
        #expect(P.state(s).rev > rev, "preset edits mark the presets changed")
        #expect(try s.execute("gradient.presets.new", ["name": "Mine"])["name"] == "Mine 2")
        try s.execute("gradient.presets.edit", ["action": "rename", "preset": "Mine", "name": "Ours"])
        #expect(throws: EngineError.self) { try s.execute("gradient.presets.edit", ["action": "rename", "preset": "Ours", "name": "Mine 2"]) }
        try s.execute("gradient.presets.edit", ["action": "move", "preset": "Mine 2", "to": "My Gradients", "index": 0])
        let mine = try #require(try listGroups(s, "gradient.presets.list").first { $0["name"] == "My Gradients" })
        #expect(mine["presets"]?[0]?["name"] == "Mine 2")
        #expect(mine["presets"]?[1]?["stops"]?[1] == [0.5, "foreground"])
        #expect(mine["presets"]?[1]?["transparency"]?[1] == [1.0, 50.0])
        try s.execute("gradient.presets.edit", ["action": "delete", "preset": ["Ours", "Mine 2"]])
        try s.execute("gradient.presets.edit", ["action": "deleteGroup", "group": "My Gradients"])
        try s.execute("gradient.presets.edit", ["action": "deleteGroup", "group": "Blues"])
        try s.execute("gradient.presets.reset")
        #expect(try listGroups(s, "gradient.presets.list").contains { $0["name"] == "Blues" })
        // Bad params.
        #expect(throws: EngineError.self) { try s.execute("gradient.presets.select", ["preset": "nope"]) }
        #expect(throws: EngineError.self) { try s.execute("gradient.presets.select", ["stops": [[0, "#zzzzzz"], [1, "#000000"]]]) }
        #expect(throws: EngineError.self) { try s.execute("gradient.presets.edit", ["action": "explode"]) }
    }

    @Test func presetsPersistThroughPreferencesJSON() throws {
        let s = Session()
        try s.execute("gradient.presets.new", ["name": "Saved", "stops": [[0, "#ff0000"], [1, "#0000ff"]]])
        try s.execute("tool.presets.new", ["name": "Big Brush", "tool": "brush", "options": ["brush": ["size": 300.0]]])
        try s.execute("shape.presets.new", ["name": "Tri", "path": "M 0 0 L 10 0 L 5 10 Z"])
        try s.execute("style.presets.edit", ["action": "deleteGroup", "group": "Buttons"])
        let blob = try JSONValue.parse(P.persistedJSON(s).serialized())
        let t = Session()
        P.loadPersisted(t, blob)
        func names(_ cmd: String, _ key: String) throws -> [String] {
            try listGroups(t, cmd).flatMap { ($0[key]?.arrayValue ?? []).compactMap { $0["name"]?.stringValue } }
        }
        #expect(try names("gradient.presets.list", "presets").contains("Saved"))
        #expect(try names("shape.presets.list", "shapes").contains("Tri"))
        #expect(try !listGroups(t, "style.presets.list").contains { $0["name"] == "Buttons" })
        let tp = try t.execute("tool.presets.list", ["tool": "Brush Tool"])
        #expect(tp["presets"]?.arrayValue?.contains { $0["name"] == "Big Brush" } == true)
        // Older preference files without presets keep the defaults.
        let u = Session()
        P.loadPersisted(u, [:])
        let all = P.State().gradients.reduce(0) { $0 + $1.items.count }
        #expect(try listGroups(u, "gradient.presets.list").reduce(0) { $0 + ($1["presets"]?.arrayValue?.count ?? 0) } == all)
    }

    // MARK: Patterns

    @Test func patternGroupsSelectApplyAndSync() throws {
        let s = try session()
        let groups = try listGroups(s, "pattern.presets.list")
        #expect(groups.first?["name"] == "Geometric")
        #expect(groups.first?["patterns"]?.arrayValue?.count == 4)
        try s.execute("pattern.presets.select", ["pattern": "Bricks"])
        // Pattern fill layers default to the selected pattern.
        let r = try s.execute("pattern.presets.apply")
        let id = LayerId(try #require(r["layer"]?.uint64Value))
        func name() -> String? {
            if case .fill(.pattern(let f))? = s.active?.doc.layer(id)?.content { return f.name }
            return nil
        }
        #expect(name() == "Bricks")
        let r2 = try s.execute("pattern.presets.select", ["pattern": "Dots"])
        #expect(r2["layer"] == .id(id))
        #expect(name() == "Dots")
        // A newly defined pattern lands in its group, and can be moved / renamed / deleted.
        let r3 = try s.execute("pattern.presets.new", ["name": "Mine", "rect": [0, 0, 8, 8], "group": "Custom"])
        let pid = try #require(r3["pattern"]?.stringValue)
        let custom = try #require(try listGroups(s, "pattern.presets.list").first { $0["name"] == "Custom" })
        #expect(custom["patterns"]?[0]?["id"] == .string(pid))
        try s.execute("pattern.presets.edit", ["action": "move", "preset": "Mine", "to": "Geometric"])
        try s.execute("pattern.presets.edit", ["action": "rename", "preset": "Mine", "name": "Ours"])
        try s.execute("pattern.presets.edit", ["action": "delete", "preset": "Ours"])
        #expect(try listGroups(s, "pattern.presets.list").first?["patterns"]?.arrayValue?.count == 4)
        // Deleting a group deletes its patterns from the library.
        try s.execute("pattern.presets.edit", ["action": "deleteGroup", "group": "Textures"])
        #expect(PatternCommands.resolve(s, "Weave") == nil)
    }

    // MARK: Shapes

    @Test func shapePathLanguageParses() throws {
        let p = try P.parseShape("M 0 0 L 10 0 L 10 10 Z ! O 5 5 2")
        #expect(p.subpaths.count == 2)
        #expect(p.subpaths[0].knots.count == 3)
        #expect(p.subpaths[1].op == .subtract)
        for bad in ["M 0 0 L x", "", "L 1 1"] { #expect(throws: P.ShapeParseError.self) { try P.parseShape(bad) } }
        // Every built-in parsed and has an area.
        for g in P.builtinShapes() {
            #expect(!g.items.isEmpty, "\(g.name)")
            for sh in g.items { #expect(P.shapeThumbnail(sh.path, 32).reduce(0, +) > 20, "\(sh.name) is empty") }
        }
        #expect(P.builtinShapes().reduce(0) { $0 + $1.items.count } >= 30)
    }

    @Test func shapesPlaceAsShapeLayers() throws {
        let s = try session()
        let r = try s.execute("shape.presets.place", ["preset": "Heart", "rect": [10, 10, 40, 20], "fill": "#ff0000"])
        #expect(r["preset"] == "Heart")
        let id = LayerId(try #require(r["layer"]?.uint64Value))
        let l = try #require(s.active?.doc.layer(id))
        #expect(l.name == "Heart")
        guard case .shape(let sh) = l.content, let b = sh.path.controlBounds else { Issue.record("not a shape layer"); return }
        // Keep aspect: 20 px tall, centred horizontally in the 40 px rect.
        #expect(abs(b.y - 10) < 0.01 && abs(b.w - 30) < 0.01, "\(b)")
        // The heart's box is 100 × 92: 20 px tall → 21.7 px wide, centred on x = 30.
        #expect(abs((b.z - b.x) - 20 * 100 / 92) < 0.05 && abs((b.x + b.z) / 2 - 30) < 0.01, "\(b)")
        #expect(sh.fill == .solid(.rgb(1, 0, 0)))
        #expect(sh.cache != nil)
        // Free (dragged without ⇧) fills the rect; negative drags flip.
        let r2 = try s.execute("shape.presets.place", ["preset": "Arrow Right", "rect": [50, 40, -40, -20], "keepAspect": false])
        guard case .shape(let sh2)? = s.active?.doc.layer(LayerId(r2["layer"]?.uint64Value ?? 0))?.content else { Issue.record("no shape"); return }
        #expect(sh2.path.controlBounds == SIMD4(10, 20, 50, 40))
        // Default placement: centred, half the short side.
        try s.execute("shape.presets.place", ["preset": "Ring"])
        #expect(throws: EngineError.self) { try s.execute("shape.presets.place", ["preset": "Unicorn"]) }
        #expect(throws: EngineError.self) { try s.execute("shape.presets.place", ["preset": "Heart", "rect": [0, 0, 0, 5]]) }
        // Undo removes the layer.
        let n = s.active?.doc.layers.count ?? 0
        try s.execute("edit.undo")
        #expect(s.active?.doc.layers.count == n - 1)
    }

    @Test func customShapesJoinTheShapesPanel() throws {
        let s = try session()
        let star = P.fit(try P.parseShape(P.star(5, 0.4, 0)), SIMD4(0, 0, 30, 30), keep: true)
        s.state[P.CustomShapesKey.self] = [P.CustomShape(name: "My Star", path: star)]
        let last = try #require(try listGroups(s, "shape.presets.list").last)
        #expect(last["name"] == .string(P.customGroup))
        try s.execute("shape.presets.place", ["preset": "My Star"])
        try s.execute("shape.presets.edit", ["action": "rename", "preset": "My Star", "name": "Star 2"])
        try s.execute("shape.presets.edit", ["action": "delete", "preset": "Star 2"])
        #expect(s.state[P.CustomShapesKey.self].isEmpty)
        // New preset from the active shape layer, normalised to the 100 box.
        try s.execute("shape.presets.new", ["name": "From Layer", "group": "Mine"])
        let g = try #require(P.state(s).shapes.first { $0.name == "Mine" })
        let b = try #require(g.items.first?.path.controlBounds)
        #expect(max(b.z, b.w) > 99.9)
    }

    @Test func shapeNewFromObjectPathAndErrors() throws {
        let s = Session()
        let path = P.pathJSON(try P.parseShape("M 0 0 L 10 0 L 5 10 Z"))
        try s.execute("shape.presets.new", ["name": "Obj", "path": path])
        let g = try #require(P.state(s).shapes.first)
        #expect(g.items.contains { $0.name == "Obj" })
        #expect(throws: EngineError.self) { try s.execute("shape.presets.new", ["path": ["subpaths": "x"]]) }
        #expect(throws: EngineError.self, "no document") { try s.execute("shape.presets.new") }
    }

    // MARK: Tool presets

    @Test func toolPresetsSaveFilterSelect() throws {
        let s = Self.brushSession()
        try s.execute("tools.setBrush", ["size": 77.0])
        try s.execute("tool.presets.new", ["name": "Seventy Seven", "tool": "brush", "includeColor": true, "options": ["toolOptions": ["x": 1]]])
        try s.execute("tools.setBrush", ["size": 5.0])
        s.tools.foreground = SIMD4(1, 0, 0, 1)
        let v = try s.execute("tool.presets.list", ["tool": "eraser"])
        #expect(v["presets"]?.arrayValue?.allSatisfy { $0["tool"] == "eraser" } == true)
        let r = try s.execute("tool.presets.select", ["preset": "Seventy Seven"])
        #expect(r["tool"] == "brush")
        #expect(r["options"]?["toolOptions"]?["x"] == 1)
        #expect(s.tools.foreground == SIMD4(0, 0, 0, 1))
        try s.execute("tool.presets.new", ["name": "Eraser 77", "tool": "eraser"])
        let r2 = try s.execute("tool.presets.select", ["preset": "Eraser 77"])
        // Selecting "Seventy Seven" restored its 77 px brush, which the new preset captured.
        #expect(r2["options"]?["brush"]?["size"] == 77.0)
        try s.execute("tool.presets.select", ["preset": "Soft Round 100 px"])
        #expect(s.tools.brush.size == 100)
        try s.execute("tool.presets.edit", ["action": "rename", "preset": "Eraser 77", "name": "E"])
        try s.execute("tool.presets.edit", ["action": "delete", "preset": "E"])
        #expect(throws: EngineError.self) { try s.execute("tool.presets.select", ["preset": "E"]) }
        #expect(throws: EngineError.self) { try s.execute("tool.presets.edit", ["action": "newGroup"]) }
        #expect(throws: EngineError.self) { try s.execute("tool.presets.new", ["name": "x"]) }
    }

    /// Crop presets are `crop` tool presets: saved, listed, persisted and deleted like the others.
    @Test func cropPresetsAreToolPresetsThatPersist() throws {
        let s = Session()
        let opts: JSONValue = ["toolOptions": ["crop_ratio": "whr", "crop_width": "4 in", "crop_height": "5 in", "crop_resolution": "300",
                                               "crop_resolution_unit": "px/in"]]
        try s.execute("tool.presets.new", ["name": "4 x 5 in 300 ppi", "tool": "crop", "options": opts])
        let r = try s.execute("tool.presets.new", ["name": "4 x 5 in 300 ppi", "tool": "crop", "options": opts])
        #expect(r["name"] == "4 x 5 in 300 ppi 2", "a taken name gets a number")
        let t = Session()
        P.loadPersisted(t, P.persistedJSON(s))
        #expect(try t.execute("tool.presets.list", ["tool": "crop"])["presets"]?.arrayValue?.count == 2)
        let sel = try t.execute("tool.presets.select", ["preset": "4 x 5 in 300 ppi"])
        #expect(sel["options"]?["toolOptions"]?["crop_width"] == "4 in")
        // Deleting several is all or nothing.
        #expect(throws: EngineError.self) { try t.execute("tool.presets.edit", ["action": "delete", "preset": ["4 x 5 in 300 ppi", "missing"]]) }
        #expect(P.state(t).toolPresets.filter { $0.tool == "crop" }.count == 2)
        let d = try t.execute("tool.presets.edit", ["action": "delete", "preset": ["4 x 5 in 300 ppi 2", "4 x 5 in 300 ppi", "4 x 5 in 300 ppi"]])
        #expect(d["deleted"] == 2)
        #expect(P.state(t).toolPresets.allSatisfy { $0.tool != "crop" })
    }

    @Test func toolPresetNamesAndParamsAreChecked() throws {
        let s = Session()
        let n = P.state(s).toolPresets.count
        let long = String(repeating: "x", count: P.maxPresetName + 1)
        let bad: [JSONValue] = [
            ["name": .string(long), "tool": "crop"], ["name": 7, "tool": "crop"], ["name": ["a"], "tool": "crop"], ["tool": 3],
            ["tool": "crop", "options": "big"], ["tool": "crop", "options": [1]], .null, [],
        ]
        for p in bad { #expect(throws: EngineError.self, "\(p)") { try s.execute("tool.presets.new", p) } }
        #expect(P.state(s).toolPresets.count == n)
        // An empty or blank name falls back to the tool's; the longest name fits.
        #expect(try s.execute("tool.presets.new", ["name": "   ", "tool": "crop"])["name"] == "crop")
        let max = String(repeating: "é", count: P.maxPresetName)
        #expect(try s.execute("tool.presets.new", ["name": .string(max), "tool": "crop"])["name"] == .string(max))
        #expect(throws: EngineError.self) { try s.execute("tool.presets.edit", ["action": "rename", "preset": "crop", "name": .string(long)]) }
        #expect(throws: EngineError.self) { try s.execute("tool.presets.edit", ["action": "rename", "preset": "crop", "name": "  "]) }
        // The store is capped.
        while P.state(s).toolPresets.count < P.maxToolPresets {
            let i = P.state(s).toolPresets.count
            s.state[P.Key.self].toolPresets.append(P.ToolPreset(name: "p\(i)", tool: "crop", options: [:]))
        }
        #expect(throws: EngineError.self) { try s.execute("tool.presets.new", ["name": "one more", "tool": "crop"]) }
    }

    /// A damaged entry in the saved tool presets is skipped; the other presets load.
    @Test func damagedToolPresetsSkipOnlyTheBadEntries() throws {
        let s = Session()
        try s.execute("gradient.presets.new", ["name": "Kept", "stops": [[0, "#ff0000"], [1, "#0000ff"]]])
        var prefs = P.persistedJSON(s)
        prefs = prefs.setting("tool_presets", [
            ["name": "Good", "tool": "crop", "options": ["toolOptions": ["crop_ratio": "2:3"]]], ["name": 5, "tool": "crop"], ["tool": "crop"],
            ["name": "   ", "tool": "crop"], ["name": .string(String(repeating: "x", count: 300)), "tool": "crop"], ["name": "No tool", "tool": ""],
            "junk", .null, ["name": "Good", "tool": "brush"], ["name": "Odd options", "tool": "crop", "options": 12],
        ])
        let t = Session()
        P.loadPersisted(t, prefs)
        #expect(P.state(t).toolPresets.map(\.name) == ["Good", "Odd options"])
        #expect(P.state(t).toolPresets.last?.options.objectValue != nil)
        #expect(P.state(t).gradients.contains { $0.items.contains { $0.name == "Kept" } }, "other presets still load")
        // Not an array at all: no tool presets, still no crash.
        let u = Session()
        P.loadPersisted(u, prefs.setting("tool_presets", ["a": 1]))
        #expect(P.state(u).toolPresets.isEmpty)
    }
}
