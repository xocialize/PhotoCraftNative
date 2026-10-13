// Port of photocraft-engine (crates/engine/src/automate_cmds/tests.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Scripts, script events, droplets (and their shell shim), Statistics and Contact Sheet II,
// driven through `s.execute` as the Rust tests are. `photocraft_codecs::decode` of an output is
// `EngineIO.importFile`; `photocraft_compose::flatten` is the session's `EngineRenderer`.
// Statistics needs `layer.smartObjects.stackMode.*`: while that command is `unavailable` in this
// build, the Statistics tests check the refusal and the stacked smart object it would act on.

import Foundation
import PCDocument
@testable import PCEngine
import PCFoundation
import Testing

/// Writes `n` small PNGs (w×h, grey level i·40 + 20) into `dir`.
fileprivate func images(_ dir: URL, _ n: Int, _ w: Int, _ h: Int) throws -> [String] {
    try (0 ..< n).map { i in
        let s = Session()
        let v = i * 40 + 20
        try s.execute("file.new", ["width": .int(w), "height": .int(h), "background": .string(String(format: "#%02x%02x%02x", v, v, v))])
        let path = dir.appendingPathComponent("img\(i).png").path
        try FileCommands.saveDoc(s, try #require(s.active).doc, path)
        return path
    }
}

fileprivate func doc(_ s: Session) throws -> Document { try #require(s.active).doc }

fileprivate func size(_ s: Session) throws -> [Int] { [try doc(s).size.width, try doc(s).size.height] }

fileprivate func decodedSize(_ path: String) throws -> [Int] {
    let bytes = [UInt8](try Data(contentsOf: URL(fileURLWithPath: path)))
    let d = try EngineIO.importFile(name: (path as NSString).lastPathComponent, bytes: bytes, services: EngineServices()).document
    return [d.size.width, d.size.height]
}

fileprivate func stackModeAvailable(_ s: Session) -> Bool { s.registry.spec("layer.smartObjects.stackMode.median")?.isAvailable == true }

@Suite struct AutomateCommandsTests {
    @Test func scriptsParseJSONAndLines() throws {
        let a = try AutomateCommands.parseScript(#"[["file.new", {"width": 10}], {"command": "layer.flattenImage"}, "edit.undo"]"#)
        #expect(a.count == 3)
        #expect(a.first?.params["width"] == 10)
        let b = try AutomateCommands.parseScript("# make a doc\nfile.new {\"width\": 12, \"height\": 8}\n\nimage.imageRotation.90cw\n")
        #expect(b.count == 2)
        #expect(b.last?.id == "image.imageRotation.90cw")
        let c = try AutomateCommands.parseScript(#"{"photocraftDroplet":1,"action":{"steps":[["file.new",{}]]}}"#)
        #expect(c.count == 1)
        #expect(throws: (any Error).self) { try AutomateCommands.parseScript("file.new {bad json") }
    }

    @Test func browseRunsAScriptFile() throws {
        let dir = try ioDir("browse")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("make.txt").path
        try Data("file.new {\"width\": 30, \"height\": 20}\nimage.imageRotation.90cw\n".utf8).write(to: URL(fileURLWithPath: path))
        let s = Session()
        #expect(try s.execute("file.scripts.browse", ["path": .string(path)])["ok"] == true)
        #expect(try size(s) == [20, 30])
        #expect(throws: (any Error).self) { try s.execute("file.scripts.browse", ["script": "no.such.command"]) }
        // A failing step stops the script and is reported.
        let r = try s.execute("file.scripts.browse", ["steps": [["layer.delete", ["layer": 999_999]], ["image.imageRotation.90cw", .object([:])]]])
        #expect(r["results"]?.arrayValue?.count == 1)
    }

    @Test func recordingBrowseScriptCapturesEachEffectOnce() throws {
        let s = Session()
        try s.execute("file.new", ["width": 12, "height": 8])
        try s.execute("actions.record", ["name": "Rotate script"])
        #expect(try s.execute("file.scripts.browse", ["steps": [["image.imageRotation.90cw", .object([:])]]])["ok"] == true)
        #expect(try size(s) == [8, 12])
        #expect(try s.execute("actions.stop")["steps"] == 1, "Browse must not be recorded a second time")
        let recorded = try s.execute("actions.get", ["action": "Rotate script"])
        #expect(recorded["steps"] == [["image.imageRotation.90cw", .object([:])]])
        try s.execute("image.imageRotation.90ccw")
        #expect(try size(s) == [12, 8])
        #expect(try s.execute("actions.play", ["action": "Rotate script"])["ran"] == 1)
        #expect(try size(s) == [8, 12])
    }

    @Test func standaloneBrowseScriptStillRunsAndJournalsConcreteCommands() throws {
        let s = Session()
        try s.execute("file.new", ["width": 12, "height": 8])
        let start = s.journal.count
        #expect(try s.execute("file.scripts.browse", ["steps": [["image.imageRotation.90cw", .object([:])]]])["ok"] == true)
        #expect(s.journal.count == start + 2, "the child and Browse retain their diagnostic journal entries")
        #expect(s.journal.count > start && s.journal[start].id == "image.imageRotation.90cw")
        #expect(try size(s) == [8, 12])
    }

    @Test func scriptEventsFireOnNewAndClose() throws {
        let s = Session()
        let r = try s.execute("file.scripts.scriptEventsManager",
                              ["add": ["event": "newDocument", "steps": [["image.imageRotation.90cw", .object([:])]], "name": "Rotate"]])
        #expect(r["enabled"] == true)
        #expect(r["bindings"]?.arrayValue?.count == 1)
        #expect(throws: (any Error).self) { try s.execute("file.scripts.scriptEventsManager", ["add": ["event": "nope", "steps": .array([])]]) }
        #expect(throws: (any Error).self) {
            try s.execute("file.scripts.scriptEventsManager", ["add": ["event": "print", "steps": [["no.such", .object([:])]]]])
        }
        try s.execute("file.new", ["width": 40, "height": 10])
        #expect(try size(s) == [10, 40], "the New Document action rotated it")
        #expect(AutomateCommands.eventLog(s).count == 1)
        // Events don't re-enter: the script's own commands fire nothing.
        try s.execute("file.scripts.scriptEventsManager", ["add": ["event": "closeDocument", "steps": [["file.new", ["width": 5, "height": 5]]]]])
        try s.execute("file.close")
        #expect(s.documents.count == 1, "closing ran the script, which made a new document")
        #expect(s.documents.first?.doc.size.width == 5, "…without the New Document rotation")
        // The bindings are preferences: they persist with them.
        let restored = Session()
        restored.loadPrefs(s.prefsValue())
        #expect(AutomateCommands.scriptEvents(restored).bindings.count == 2)
        // Disabled: nothing fires.
        try s.execute("file.scripts.scriptEventsManager", ["enabled": false])
        try s.execute("file.new", ["width": 40, "height": 10])
        #expect(try doc(s).size.width == 40)
        let cleared = try s.execute("file.scripts.scriptEventsManager", ["removeAll": true])
        #expect(cleared["bindings"]?.arrayValue?.isEmpty == true)
        #expect(cleared["events"]?.arrayValue?.count == AutomateCommands.events.count)
    }

    @Test func dropletsAreWrittenAndRun() throws {
        let dir = try ioDir("droplet")
        defer { try? FileManager.default.removeItem(at: dir) }
        let inputs = try images(dir, 2, 40, 20)
        let s = Session()
        let path = dir.appendingPathComponent("Rotate").path
        let out = dir.appendingPathComponent("out")
        let r = try s.execute("file.automate.createDroplet", ["path": .string(path), "steps": [["image.imageRotation.90cw", .object([:])]], "format": "png",
                                                              "output": .string(out.path)])
        let dp = try #require(r["path"]?.stringValue)
        #expect(dp.hasSuffix("Rotate.pcdroplet"))
        let v = try JSONValue.parse(try Data(contentsOf: URL(fileURLWithPath: dp)))
        #expect(v["photocraftDroplet"] == 1)
        let shim = try #require(r["shim"]?.stringValue)
        let text = try String(contentsOfFile: shim, encoding: .utf8)
        #expect(text.hasPrefix("#!/bin/sh") && text.contains("droplet"))
        let perms = try #require(try FileManager.default.attributesOfItem(atPath: shim)[.posixPermissions] as? Int)
        #expect(perms & 0o111 != 0, "executable")
        let run = try s.execute("file.automate.runDroplet", ["droplet": .string(dp), "input": .strings([dir.path])])
        #expect(run["files"]?.arrayValue?.count == inputs.count, "\(run.serialized())")
        #expect(try decodedSize(out.appendingPathComponent("img0.png").path) == [20, 40])
        #expect(throws: (any Error).self) { try s.execute("file.automate.createDroplet", ["path": .string(path), "steps": [["bogus", .object([:])]]]) }
    }

    @Test func dropletShimPassesShellMetacharactersAsALiteralPath() throws {
        let dir = try ioDir("droplet-shell-quote")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.path + "/Droplet's \"quote\" $HOME `printf expanded` $(touch shim-injected) \\\nline"
        let s = Session()
        let result = try s.execute("file.automate.createDroplet", ["path": .string(path), "steps": [["file.new", .object([:])]]])
        let droplet = try #require(result["path"]?.stringValue)
        let shim = try #require(result["shim"]?.stringValue)
        let cli = dir.appendingPathComponent("cli stub").path
        let capture = dir.appendingPathComponent("captured path").path
        let marker = dir.appendingPathComponent("shim-injected").path
        let input = dir.appendingPathComponent("input file").path
        try Data(#"""
        #!/bin/sh
        if [ "$#" -ne 3 ] || [ "$1" != droplet ] || [ "$3" != "$PHOTOCRAFT_EXPECTED_INPUT" ]; then exit 90; fi
        printf '%s' "$2" > "$PHOTOCRAFT_CAPTURE"

        """#.utf8).write(to: URL(fileURLWithPath: cli))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: shim)
        proc.arguments = [input]
        proc.currentDirectoryURL = dir
        proc.environment = ["PHOTOCRAFT_CLI": cli, "PHOTOCRAFT_CAPTURE": capture, "PHOTOCRAFT_EXPECTED_INPUT": input, "PATH": "/usr/bin:/bin"]
        try proc.run()
        proc.waitUntilExit()
        #expect(proc.terminationStatus == 0, "shim exited \(proc.terminationStatus)")
        #expect(!FileManager.default.fileExists(atPath: marker), "filename command substitution ran")
        let expected = try #require(AutomateCommands.canonicalPath(droplet))
        #expect(try Data(contentsOf: URL(fileURLWithPath: capture)) == Data(expected.utf8))
    }

    @Test func dropletsCarryTheActionsTheirPlayStepsCall() throws {
        let dir = try ioDir("droplet-called")
        defer { try? FileManager.default.removeItem(at: dir) }
        let inputs = try images(dir, 2, 40, 20)
        let s = Session()
        func act(_ name: String, _ steps: [CommandInvocation]) -> ActionsCommands.Action { ActionsCommands.Action(name, steps) }
        s.state[ActionsCommands.ActionStateKey.self].list = [
            act("Unrelated", [CommandInvocation("image.imageRotation.180")]),
            act("Rotate", [CommandInvocation("image.imageRotation.90cw")]),
            // Calls Rotate by index (as the panel records it) and itself (caught at run time).
            act("Outer", [CommandInvocation("actions.play", ["action": 1])]),
            act("Loop", [CommandInvocation("actions.play", ["action": "Loop"])]),
        ]
        func make(_ name: String, _ steps: JSONValue) throws -> String {
            let path = dir.appendingPathComponent(name).path
            let out = dir.appendingPathComponent("out-\(name)").path
            let r = try s.execute("file.automate.createDroplet", ["path": .string(path), "steps": steps, "format": "png", "output": .string(out), "shim": false])
            return try #require(r["path"]?.stringValue)
        }
        let dp = try make("Outer", [["actions.play", ["action": "Outer"]]])
        let looping = try make("Loop", [["actions.play", ["action": "Loop"]]])
        let v = try JSONValue.parse(try Data(contentsOf: URL(fileURLWithPath: dp)))
        #expect(v["actions"] == nil, "the CLI reads `actions` as an action set")
        #expect(v["calledActions"]?.arrayValue?.compactMap { $0["name"]?.stringValue } == ["Rotate", "Outer"], "only the called actions, transitively")
        // A fresh session, as `photocraft-cli droplet` and the droplet shim use.
        let fresh = Session()
        let r = try fresh.execute("file.automate.runDroplet", ["droplet": .string(dp), "input": .strings([dir.path])])
        #expect(r["files"]?.arrayValue?.count == inputs.count, "\(r.serialized())")
        #expect(try decodedSize(dir.appendingPathComponent("out-Outer/img0.png").path) == [20, 40])
        let rl = try fresh.execute("file.automate.runDroplet", ["droplet": .string(looping), "input": .strings([dir.path])])
        #expect(rl["errors"]?.arrayValue?.count == inputs.count, "a self-call fails instead of looping: \(rl.serialized())")
        // Droplets written before `calledActions` still run.
        let old = dir.appendingPathComponent("old.pcdroplet").path
        let ov: JSONValue = ["photocraftDroplet": 1, "action": ["steps": [["image.imageRotation.90cw", .object([:])]]],
                             "options": ["output": .string(dir.appendingPathComponent("out-old").path)]]
        try Data(ov.serialized().utf8).write(to: URL(fileURLWithPath: old))
        let ro = try fresh.execute("file.automate.runDroplet", ["droplet": .string(old), "input": .strings([dir.path])])
        #expect(ro["files"]?.arrayValue?.count == inputs.count, "\(ro.serialized())")
    }

    @Test func batchAndDropletsSkipRecordedViewSteps() throws {
        let dir = try ioDir("view-steps")
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try images(dir, 1, 40, 20)
        let steps: JSONValue = [["view.zoomIn", .object([:])], ["image.imageRotation.90cw", .object([:])], ["view.fitOnScreen", .object([:])]]
        let s = Session()
        let r = try s.execute("file.automate.batch", ["steps": steps, "input": .string(dir.path), "output": .string(dir.appendingPathComponent("batch").path),
                                                      "format": "png"])
        #expect(r["errors"]?.arrayValue?.isEmpty == true, "\(r.serialized())")
        #expect(try decodedSize(dir.appendingPathComponent("batch/img0.png").path) == [20, 40])
        let d = try s.execute("file.automate.createDroplet", ["path": .string(dir.appendingPathComponent("Rotate").path), "steps": steps])
        let v = try JSONValue.parse(try Data(contentsOf: URL(fileURLWithPath: try #require(d["path"]?.stringValue))))
        #expect(v["action"]?["steps"] == [["image.imageRotation.90cw", .object([:])]])
    }

    @Test func statisticsMakesAStackModeSmartObject() throws {
        let dir = try ioDir("stats")
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = try images(dir, 3, 16, 12)
        let s = Session()
        #expect(throws: (any Error).self) { try s.execute("file.scripts.statistics", ["mode": "average", "input": .string(dir.path)]) }
        guard stackModeAvailable(s) else {
            let e = #expect(throws: EngineError.self) { try s.execute("file.scripts.statistics", ["mode": "mean", "input": .strings(files)]) }
            if case .unavailable(let id, _)? = e { #expect(id == "layer.smartObjects.stackMode.mean") } else { Issue.record("\(String(describing: e))") }
            return
        }
        let r = try s.execute("file.scripts.statistics", ["mode": "mean", "input": .strings(files)])
        #expect(r["images"] == 3)
        let d = try doc(s)
        #expect(d.layers.count == 1)
        guard case .smart(let so) = d.layers[0].content else { Issue.record("not a smart object"); return }
        #expect(so.stackMode == .mean)
        // Mean of 20, 60, 100 = 60.
        let px = try s.services.renderer.pixel(d, x: 0, y: 0)
        #expect(abs(px.x * 255 - 60) < 1.5, "\(px)")
    }

    /// Like Photoshop, Load Files into Stack › Create Smart Object (Statistics without alignment)
    /// and Statistics with alignment embed one layer per file, bottom to top, with no wrapper group.
    @Test func stackedSmartObjectHoldsTheLoadedLayersAtItsTopLevel() throws {
        let dir = try ioDir("stack-top")
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = Session()
        try src.execute("file.new", ["width": 96, "height": 72, "background": "#606060"])
        let bg = try #require(src.active?.activeLayer)
        try src.edit("texture") { doc, _ in
            _ = doc.withRaster(of: bg) { surf in
                for k in 0 ..< 40 {
                    let (x, y, v) = (Int32((k * 37) % 88), Int32((k * 23) % 66), Float(k % 7) / 6)
                    let r = PixelRect(x0: x, y0: y, x1: x + 3 + Int32(k % 5), y1: y + 2 + Int32(k % 4))
                    surf.writeRegion(r, PixelCodec.fromRGBA(surf.format, rgba: [SIMD4<Float>](repeating: SIMD4(v, 1 - v, 0.5, 1), count: r.width * r.height)))
                }
            }
        }
        let source = try src.services.renderer.render(try doc(src), region: try doc(src).bounds).px
        let files = try (0 ..< 3).map { i -> String in
            let path = dir.appendingPathComponent("img\(i).png").path
            try FileCommands.saveDoc(src, try doc(src), path)
            return path
        }
        for align in [false, true] {
            let s = Session()
            if stackModeAvailable(s) {
                try s.execute("file.scripts.statistics", ["mode": "median", "input": .strings(files), "align": .bool(align)])
            } else if align {
                continue
            } else {
                // Statistics' first half: the stacked smart object Stack Mode would act on.
                try s.execute("file.scripts.loadFilesIntoStack", ["paths": .strings(files), "createSmartObject": true])
            }
            let d = try doc(s)
            guard case .smart(let so) = d.layers[0].content, case .embedded(let name, let bytes) = so.source else { Issue.record("an embedded smart object"); continue }
            let inner = try EngineIO.importFile(name: name, bytes: bytes, services: EngineServices()).document
            #expect(inner.layers.map(\.name) == ["img0.png", "img1.png", "img2.png"], "align \(align)")
            #expect(try s.services.renderer.render(d, region: d.bounds).px == source, "align \(align)")
        }
    }

    @Test func contactSheetPlacesThumbnailsWithCaptions() throws {
        let dir = try ioDir("contact")
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try images(dir, 5, 60, 30)
        for depth in [8, 16] {
            let s = Session()
            let r = try s.execute("file.automate.contactSheetII", ["input": .string(dir.path), "units": "pixels", "width": 400, "height": 300, "resolution": 72,
                                                                   "columns": 2, "rows": 2, "depth": .int(depth), "fontSize": 10, "rotateForBestFit": true])
            #expect(r["pages"] == 2, "5 images on 2×2 sheets")
            #expect(r["images"] == 5)
            let first = try #require(r["documents"]?.arrayValue?.first?.uint64Value.map(Int.init))
            let d = s.documents[first].doc
            #expect(d.size.width == 400 && d.size.height == 300)
            let names = d.layers.map(\.name)
            #expect(names.contains("img0") && names.contains("img3"), "\(names)")
            let texts = d.layers.filter { if case .text = $0.content { true } else { false } }.count
            #expect(texts == 4, "a caption per image")
            let thumb = try #require(d.layers.first { l in
                if case .raster = l.content { return l.name == "img0" }
                return false
            })
            let b = thumb.surface?.contentBounds ?? .empty
            #expect(b.width <= 200 && b.height < 150, "fits its cell: \(b)")
            // Flattened variant.
            let f = try s.execute("file.automate.contactSheetII", ["input": .string(dir.path), "units": "pixels", "width": 200, "height": 200, "columns": 3, "rows": 2,
                                                                   "caption": false, "flatten": true])
            let fi = try #require(f["documents"]?.arrayValue?.first?.uint64Value.map(Int.init))
            #expect(s.documents[fi].doc.layers.count == 1)
        }
    }

    @Test func aFailedStepInsideACalledActionFailsScriptsAndBatch() throws {
        let dir = try ioDir("nested-failure")
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try images(dir, 1, 8, 4)
        let s = Session()
        try s.execute("file.new", ["width": 8, "height": 6])
        s.state[ActionsCommands.ActionStateKey.self].list.append(ActionsCommands.Action("Rotate", [CommandInvocation("image.imageRotation.90cw")]))
        s.state[ActionsCommands.ActionStateKey.self].list.append(ActionsCommands.Action("Bad", [CommandInvocation("layer.delete", ["layer": 999_999])]))
        // A script stops at the failed call and reports it.
        let r = try s.execute("file.scripts.browse", ["steps": [["actions.play", ["action": "Bad"]], ["image.imageRotation.90cw", .object([:])]]])
        #expect(r["ok"] == false, "\(r.serialized())")
        #expect(r["results"]?.arrayValue?.count == 1)
        // Batch plays called actions, and a failure inside one is a file error, not a saved result.
        func batch(_ action: String) throws -> JSONValue {
            try s.execute("file.automate.batch", ["steps": [["actions.play", ["action": .string(action)]]], "input": .string(dir.path),
                                                  "output": .string(dir.appendingPathComponent(action).path), "format": "png"])
        }
        #expect(try batch("Rotate")["errors"]?.arrayValue?.isEmpty == true)
        let bad = try batch("Bad")
        #expect(bad["files"] == .array([]), "\(bad.serialized())")
        #expect(bad["errors"]?.arrayValue?.first?["error"]?.stringValue?.contains("no such layer") == true, "\(bad.serialized())")
        // An action that batches itself stops as a recursive call instead of overflowing the stack.
        let inner: JSONValue = ["steps": [["actions.play", ["action": "Loop"]]], "input": .string(dir.path), "output": .string(dir.appendingPathComponent("inner").path),
                                "format": "png"]
        s.state[ActionsCommands.ActionStateKey.self].list.append(ActionsCommands.Action("Loop", [CommandInvocation("file.automate.batch", inner)]))
        _ = try batch("Loop")
    }
}
