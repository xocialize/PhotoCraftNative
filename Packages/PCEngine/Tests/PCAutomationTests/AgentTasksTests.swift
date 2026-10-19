// Port of photocraft-automation's M11 acceptance tests (crates/automation/tests/agent_tasks.rs `agent_completes_ten_scripted_tasks`, `agent_edits_text_by_position`, `agent_completes_ten_more_scripted_tasks`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// An agent completes scripted edit tasks over MCP: each task uses only MCP tools (`doc_*`,
// `command_run`) the way an agent would, and checks the outcome through `doc_inspect`,
// `document.pixel` or the exported files, never engine internals. The other two tests of
// agent_tasks.rs are in MCPServerTests.

import Foundation
import MCP
@testable import PCAutomation
import PCDocument
import PCEngine
import PCFoundation
import PCPlatform
import Testing

@Suite struct AgentTasksTests {
    /// A connected agent: tool calls that fail the test on a tool error.
    struct Agent {
        let c: Client

        func tool(_ name: String, _ args: JSONValue = .object([:]), sourceLocation: SourceLocation = #_sourceLocation) async throws -> JSONValue {
            let r = try await call(c, name, args)
            #expect(r.isError != true, "\(name) failed: \(text(r))", sourceLocation: sourceLocation)
            return (try? JSONValue.parse(text(r))) ?? .string(text(r))
        }

        func run(_ id: String, _ params: JSONValue = .object([:]), sourceLocation: SourceLocation = #_sourceLocation) async throws -> JSONValue {
            try await tool("command_run", ["id": .string(id), "params": params], sourceLocation: sourceLocation)
        }

        func inspect() async throws -> JSONValue { try await tool("doc_inspect") }

        /// Composite RGBA at (x, y), whatever envelope `command_run` wraps the result in.
        func pixel(_ x: Int, _ y: Int) async throws -> [Double] {
            let v = try await run("document.pixel", ["x": .int(x), "y": .int(y)])
            let arr = v.arrayValue ?? v["result"]?.arrayValue ?? []
            return arr.compactMap(\.doubleValue)
        }
    }

    func close(_ a: [Double], _ b: [Double], _ tol: Double) -> Bool { a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) <= tol } }

    /// A 64×48 RGB gradient PNG (red ramps across, green down).
    func gradientPNG(_ dir: URL) throws -> String {
        let (w, h) = (64, 48)
        var px: [Float] = []
        px.reserveCapacity(w * h * 3)
        for y in 0..<h {
            for x in 0..<w { px += [Float(x * 4) / 255, Float(y * 5) / 255, 128 / 255] }
        }
        try ImageCodecs.encode(RasterBuffer(width: w, height: h, format: PixelFormat(mode: .rgb, sample: .u8, alpha: false), floats: px), as: .png).write(to: dir.appendingPathComponent("gradient.png"))
        return "gradient.png"
    }

    @Test func agentCompletesTenScriptedTasks() async throws {
        let dir = try tempDir("agent-tasks")
        defer { try? FileManager.default.removeItem(at: dir) }
        let png = try gradientPNG(dir)
        let (c, s) = try await connect(try headlessIn(dir))
        let a = Agent(c: c)

        // 1. Make a title card: type layer with a drop shadow, exported as PNG.
        _ = try await a.tool("doc_new", ["width": 200, "height": 120, "background": "white"])
        _ = try await a.run("type.create", ["x": 20, "y": 70, "text": "Hello", "size": 36])
        _ = try await a.run("layer.layerStyle.dropShadow", ["distance": 4, "size": 3])
        var doc = try await a.inspect()
        let t = doc["layers"]?[0] ?? .null
        #expect(t["kind"] == "Type", "task 1: \(t)")
        #expect(t["text"]?["text"] == "Hello", "task 1: \(t)")
        #expect(t["effects"]?["items"]?[0]?["kind"] == "Drop Shadow", "task 1: \(t)")
        _ = try await a.tool("doc_export", ["path": "card.png"])
        #expect(try ImageCodecs.decode(Data(contentsOf: dir.appendingPathComponent("card.png"))).size == PixelSize(width: 200, height: 120), "task 1")
        _ = try await a.tool("doc_close")

        // 2. Colour grade a photo non-destructively: Curves brightens the midtones, Vibrance on top.
        _ = try await a.tool("doc_open", ["path": .string(png)])
        let before = try await a.pixel(16, 24)
        _ = try await a.run("layer.newAdjustmentLayer.curves", ["points": [[0, 0], [128, 200], [255, 255]]])
        _ = try await a.run("layer.newAdjustmentLayer.vibrance", ["vibrance": 40, "saturation": 0])
        let after = try await a.pixel(16, 24)
        #expect(after.count == 4 && before.count == 4 && after[1] > before[1] + 0.05, "task 2: curves should brighten green \(before) -> \(after)")
        doc = try await a.inspect()
        #expect((doc["layers"]?.arrayValue ?? []).compactMap { $0["kind"]?.stringValue } == ["Adjustment", "Adjustment", "Pixel"], "task 2")

        // 3. Undo/redo: remove both adjustments, restore one.
        _ = try await a.run("edit.undo")
        _ = try await a.run("edit.undo")
        #expect(close(try await a.pixel(16, 24), before, 1e-6), "task 3: undo should restore the original")
        _ = try await a.run("edit.redo")
        #expect(try await a.inspect()["layers"]?.arrayValue?.count == 2, "task 3: redo restores Curves")
        _ = try await a.run("edit.undo")

        // 4. Editable blur: smart object + Gaussian Blur, retune the radius, then hide the filter.
        _ = try await a.run("layer.smartObjects.convertToSmartObject")
        _ = try await a.run("filter.blur.gaussianBlur", ["radius": 2])
        _ = try await a.run("layer.smartFilter.setParams", ["index": 0, "params": ["radius": 6]])
        doc = try await a.inspect()
        let sf = doc["layers"]?[0]?["smartFilters"]?[0] ?? .null
        #expect(sf["command"] == "filter.blur.gaussianBlur", "task 4: \(doc)")
        #expect(sf["params"]?["radius"]?.doubleValue == 6, "task 4: \(sf)")
        _ = try await a.run("layer.smartFilter.setVisible", ["index": 0, "visible": false])
        #expect(close(try await a.pixel(16, 24), before, 1.0 / 255), "task 4: hiding the filter restores the pixels")

        // 5. Selection → layer mask: an elliptical reveal on a red layer.
        _ = try await a.run("layer.new.layer", ["name": "Red"])
        _ = try await a.run("select.all")
        _ = try await a.run("edit.fill", ["color": "#ff0000"])
        _ = try await a.run("select.rect", ["x": 16, "y": 12, "width": 32, "height": 24, "ellipse": true])
        _ = try await a.run("layer.layerMask.revealSelection")
        #expect(try await a.inspect()["layers"]?[0]?["hasMask"] == true, "task 5")
        let inside = try await a.pixel(32, 24), outside = try await a.pixel(1, 1)
        #expect(inside.count == 4 && inside[0] > 0.99 && inside[1] < 0.01, "task 5: centre is red \(inside)")
        #expect(outside.count == 4 && outside[0] < 0.1, "task 5: corner shows the photo \(outside)")
        #expect(try await a.inspect()["selectionBounds"] == .null, "task 5: Reveal Selection uses the selection up")

        // 6. Save a selection to a channel and load it back.
        _ = try await a.run("select.rect", ["x": 4, "y": 6, "width": 20, "height": 10])
        _ = try await a.run("select.saveSelection", ["name": "Keep"])
        _ = try await a.run("select.deselect")
        #expect(try await a.inspect()["hasSelection"] == false, "task 6")
        _ = try await a.run("select.loadSelection", ["channel": "Keep"])
        doc = try await a.inspect()
        #expect(doc["selectionBounds"] == [4, 6, 20, 10], "task 6: \(doc["selectionBounds"] ?? .null)")
        #expect(doc["channels"]?["alpha"]?[0]?["name"] == "Keep", "task 6")
        _ = try await a.run("select.deselect")
        _ = try await a.tool("doc_close")

        // 7. Lay out three swatches and align their left edges.
        _ = try await a.tool("doc_new", ["width": 120, "height": 90, "background": "white"])
        for (i, x) in [10, 40, 70].enumerated() {
            _ = try await a.run("layer.new.layer", ["name": .string("S\(i)")])
            _ = try await a.run("select.rect", ["x": .int(x), "y": .int(10 + 25 * i), "width": 20, "height": 15])
            _ = try await a.run("edit.fill", ["color": "#3366cc"])
        }
        _ = try await a.run("select.deselect")
        _ = try await a.run("select.allLayers")
        _ = try await a.run("layer.align.leftEdges")
        doc = try await a.inspect()
        let xs = (doc["layers"]?.arrayValue ?? []).filter { $0["name"]?.stringValue?.hasPrefix("S") == true }.compactMap { $0["bounds"]?[0]?.intValue }
        #expect(xs == [10, 10, 10], "task 7: \(doc["layers"] ?? .null)")

        // 8. Export through the capability-scoped document API.
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("layers"), withIntermediateDirectories: true)
        _ = try await a.tool("doc_export", ["path": "layers/swatch.png"])
        #expect(contents(dir.appendingPathComponent("layers")).filter { $0.hasSuffix(".png") }.count == 1, "task 8: capability-scoped export")

        // 9. Resize, then crop to a square.
        _ = try await a.run("image.imageSize", ["width": 60, "height": 45])
        _ = try await a.run("image.crop", ["x": 5, "y": 0, "width": 45, "height": 45])
        doc = try await a.inspect()
        #expect(doc["width"] == 45 && doc["height"] == 45, "task 9")

        // 10. Prepare for print: convert to CMYK and save natively, then reopen.
        _ = try await a.run("image.mode.cmyk", ["intent": "perceptual"])
        #expect(try await a.inspect()["mode"] == "Cmyk", "task 10")
        _ = try await a.tool("doc_save", ["path": "print.pcraft"])
        _ = try await a.tool("doc_close")
        _ = try await a.tool("doc_open", ["path": "print.pcraft"])
        doc = try await a.inspect()
        #expect(doc["mode"] == "Cmyk" && doc["width"] == 45, "task 10")
        #expect(doc["layers"]?.arrayValue?.count == 4, "task 10")
        await disconnect(c, s)
    }

    /// Click just after "Big", insert a word, then bold through the end of the line. Geometry
    /// comes from `type.hitTest` / `type.caret` / `type.navigate`; the edit is `type.edit`.
    @Test func agentEditsTextByPosition() async throws {
        let dir = try tempDir("agent-type-caret")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (c, s) = try await connect(try headlessIn(dir))
        let a = Agent(c: c)
        _ = try await a.tool("doc_new", ["width": 480, "height": 200, "background": "white"])
        let ids = (try await a.tool("command_list", ["filter": "type."]).arrayValue ?? []).compactMap { $0["id"]?.stringValue }
        for id in ["type.hitTest", "type.caret", "type.navigate"] { #expect(ids.contains(id), "command_list missing \(id)") }

        _ = try await a.run("type.create", ["x": 40, "y": 90, "text": "Big Sale", "size": 48])
        let before = try await a.inspect()["history"]?.arrayValue?.count
        // The caret after "Big" and the caret after the following space. A quarter of the way is
        // the left half of that space, which hit-tests as the caret after "Big".
        let afterBig = try await a.run("type.caret", ["index": 3])
        let afterSpace = try await a.run("type.caret", ["index": 4])
        let seg = afterBig["segment"]
        let x3 = try #require(seg?[0]?[0]?.doubleValue), y0 = try #require(seg?[0]?[1]?.doubleValue), y1 = try #require(seg?[1]?[1]?.doubleValue)
        let x4 = try #require(afterSpace["segment"]?[0]?[0]?.doubleValue)
        #expect(x4 > x3 + 0.5, "space should have width, caret x \(x3) -> \(x4)")
        let hit = try await a.run("type.hitTest", ["x": .number(x3 + 0.25 * (x4 - x3)), "y": .number((y0 + y1) / 2)])
        #expect(hit["index"] == 3, "\(hit)")
        #expect(hit["inside"] == true, "\(hit)")
        #expect(try await a.inspect()["history"]?.arrayValue?.count == before, "caret queries are not history steps")

        let index = hit["index"] ?? .null
        _ = try await a.run("type.edit", ["replace": ["start": index, "end": index, "text": " Summer"]])
        var info = try await a.run("type.info")
        #expect(info["text"] == "Big Summer Sale", "\(info)")

        let end = try await a.run("type.navigate", ["index": 0, "move": "lineEnd"])
        #expect(end["index"]?.intValue == info["text"]?.stringValue?.count, "\(end)")
        // "Summer" starts one character after the insertion caret (the space in " Summer").
        let summer = (index.intValue ?? 0) + 1
        _ = try await a.run("type.setStyle", ["range": [.int(summer), end["index"] ?? .null], "fauxBold": true])
        info = try await a.run("type.info")
        #expect(info["text"] == "Big Summer Sale")
        let bold = try #require((info["runs"]?.arrayValue ?? []).first { $0["style"]?["faux_bold"] == true }, "no bold run in \(info)")
        #expect(bold["start"]?.intValue == summer, "\(bold)")
        #expect(bold["end"] == end["index"], "\(bold)")
        _ = try await a.tool("doc_close")
        await disconnect(c, s)
    }

    /// The next ten acceptance tasks (11–20): strokes, inverse fills, duplication, merges,
    /// flattening, adjustments, feathering, expand, renaming/deleting and an export/reopen round
    /// trip — all through MCP tools and checked from outside the engine.
    @Test func agentCompletesTenMoreScriptedTasks() async throws {
        let dir = try tempDir("agent-tasks2")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (c, s) = try await connect(try headlessIn(dir))
        let a = Agent(c: c)

        // 11. Stroke a selection: a red square with a black outside stroke.
        _ = try await a.tool("doc_new", ["width": 80, "height": 80, "background": "white"])
        _ = try await a.run("select.rect", ["x": 20, "y": 20, "width": 40, "height": 40])
        _ = try await a.run("edit.fill", ["color": "#ff0000"])
        _ = try await a.run("edit.stroke", ["width": 4, "color": "#000000", "location": "outside"])
        let inside = try await a.pixel(40, 40), edge = try await a.pixel(18, 40), away = try await a.pixel(5, 5)
        #expect(inside[0] > 0.99 && inside[1] < 0.01, "task 11: the centre is red \(inside)")
        #expect(edge[0] < 0.1 && edge[1] < 0.1, "task 11: the stroke is black \(edge)")
        #expect(away[0] > 0.99 && away[1] > 0.99, "task 11: outside stays white \(away)")
        _ = try await a.run("select.deselect")

        // 12. Inverse the selection: a blue frame around the red square.
        _ = try await a.run("select.rect", ["x": 20, "y": 20, "width": 40, "height": 40])
        _ = try await a.run("select.inverse")
        _ = try await a.run("edit.fill", ["color": "#0000ff"])
        let centre = try await a.pixel(40, 40), frame = try await a.pixel(4, 4)
        #expect(centre[0] > 0.99 && centre[2] < 0.01, "task 12: the centre keeps red \(centre)")
        #expect(frame[2] > 0.99 && frame[0] < 0.01, "task 12: the frame is blue \(frame)")
        _ = try await a.run("select.deselect")

        // 13. Paint a green patch on a new layer and duplicate it (offset, as Photoshop's default).
        _ = try await a.run("layer.new.layer", ["name": "Patch"])
        _ = try await a.run("select.rect", ["x": 10, "y": 10, "width": 20, "height": 20])
        _ = try await a.run("edit.fill", ["color": "#00ff00"])
        _ = try await a.run("select.deselect")
        _ = try await a.run("layer.duplicate")
        var doc = try await a.inspect()
        #expect(doc["layers"]?.arrayValue?.count == 3, "task 13: \(doc)")
        #expect((doc["layers"]?.arrayValue ?? []).filter { $0["name"]?.stringValue?.hasPrefix("Patch") == true }.count == 2, "task 13: \(doc)")

        // 14. Merge the copy down; the two patches become one layer.
        _ = try await a.run("layer.mergeDown")
        #expect(try await a.inspect()["layers"]?.arrayValue?.count == 2, "task 14")

        // 15. Flatten the image; the patch survives.
        _ = try await a.run("layer.flattenImage")
        doc = try await a.inspect()
        #expect(doc["layers"]?.arrayValue?.count == 1, "task 15: \(doc)")
        let green = try await a.pixel(20, 20)
        #expect(green[1] > 0.99 && green[0] < 0.01, "task 15: the patch survives \(green)")

        // 16. A Hue/Saturation adjustment layer turns the red square green without touching pixels.
        _ = try await a.run("layer.newAdjustmentLayer.hueSaturation", ["hue": 120])
        #expect(try await a.inspect()["layers"]?[0]?["kind"] == "Adjustment", "task 16")
        let shifted = try await a.pixel(40, 40)
        #expect(shifted[1] > 0.5 && shifted[0] < 0.5, "task 16: red turns green \(shifted)")
        _ = try await a.run("layer.delete")

        // 17. Feather the selection and reveal a mask through it: the edge blends.
        _ = try await a.run("select.rect", ["x": 20, "y": 20, "width": 40, "height": 40])
        _ = try await a.run("select.modify.feather", ["radius": 4])
        _ = try await a.run("layer.layerMask.revealSelection")
        #expect(try await a.inspect()["layers"]?[0]?["hasMask"] == true, "task 17")
        let boundary = try await a.pixel(20, 40)
        #expect(boundary[3] > 0.05 && boundary[3] < 0.95, "task 17: the feathered edge keeps partial alpha \(boundary)")

        // 18. Expand a selection and read its bounds back.
        _ = try await a.run("select.rect", ["x": 20, "y": 20, "width": 20, "height": 20])
        _ = try await a.run("select.modify.expand", ["radius": 5])
        let bounds = try await a.inspect()["selectionBounds"]
        let x = try #require(bounds?[0]?.intValue, "task 18: \(String(describing: bounds))"), w = try #require(bounds?[2]?.intValue)
        #expect((13...15).contains(x) && (30...32).contains(w), "task 18: expanded outward \(String(describing: bounds))")
        _ = try await a.run("select.deselect")

        // 19. Rename a layer and delete it again.
        _ = try await a.run("layer.new.layer", ["name": "Scratch"])
        _ = try await a.run("layer.renameLayer", ["name": "Delivery"])
        #expect(try await a.inspect()["layers"]?[0]?["name"] == "Delivery", "task 19")
        _ = try await a.run("layer.delete")
        #expect(try await a.inspect()["layers"]?.arrayValue?.count == 1, "task 19: deleted")

        // 20. Export the final image and reopen the PNG as a flat document.
        _ = try await a.tool("doc_export", ["path": "final.png"])
        _ = try await a.tool("doc_close")
        _ = try await a.tool("doc_open", ["path": "final.png"])
        doc = try await a.inspect()
        #expect(doc["width"] == 80 && doc["height"] == 80, "task 20")
        #expect(doc["layers"]?.arrayValue?.count == 1, "task 20: a flat reopen")
        _ = try await a.tool("doc_close")
        await disconnect(c, s)
    }
}
