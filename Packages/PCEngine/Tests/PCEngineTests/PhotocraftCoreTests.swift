// Port of photocraft-engine (crates/engine/src/tests.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// The engine's core tests, ported one for one where they need only the core commands (the
// cross-module ones — Fill, brush strokes, paths, type — live in CrossModuleTests.swift).

import Foundation
import PCDocument
import PCEngine
import PCFoundation
import Synchronization
import Testing

/// A session with one 64×48 white document (photocraft `session_with_doc`).
func sessionWithDoc() throws -> Session {
    let s = Session()
    try s.execute("file.new", ["width": 64, "height": 48])
    return s
}

/// The composite pixel at (x, y), straight RGBA (photocraft `px`).
func px(_ s: Session, _ x: Int, _ y: Int) throws -> [Float] {
    try #require(try s.execute("document.pixel", ["x": .int(x), "y": .int(y)]).arrayValue).map { Float($0.doubleValue ?? .nan) }
}

/// The id a layer-creating command returned.
func layerResult(_ r: JSONValue) throws -> LayerId { LayerId(try #require(r["layer"]?.uint64Value)) }

func newLayer(_ s: Session, _ name: String? = nil) throws -> LayerId {
    try layerResult(try s.execute("layer.new.layer", name.map { ["name": .string($0)] } ?? .object([:])))
}

func isBadParams(_ e: any Error) -> Bool {
    if case .badParams? = e as? EngineError { return true }
    return false
}

func names(_ s: Session) -> [String] { s.active?.doc.layers.map(\.name) ?? [] }

func pastCount(_ s: Session) -> Int { s.active?.history.pastCount ?? -1 }

func selectionBounds(_ s: Session) throws -> JSONValue? { try s.execute("document.inspect")["selectionBounds"] }

/// Runs `body` on a thread with an 8 MB stack, like the app's main thread. Swift Testing runs
/// tests on 512 KB cooperative threads, which a debug build's recursive `Equatable` over 100
/// nested groups (photocraft's `MAX_GROUP_DEPTH`) overflows.
func onLargeStack(_ body: @escaping @Sendable () throws -> Void) throws {
    let failure = Mutex<(any Error)?>(nil)
    let done = DispatchSemaphore(value: 0)
    let t = Thread {
        do { try body() } catch { failure.withLock { $0 = error } }
        done.signal()
    }
    t.stackSize = 8 << 20
    t.start()
    done.wait()
    if let e = failure.withLock({ $0 }) { throw e }
}

@Suite struct PhotocraftCoreTests {
    @Test func successfulSaveIdentityIsNotUndoneOrRedone() throws {
        for depth in [8, 16, 32] {
            let s = Session()
            try s.execute("file.new", ["width": 4, "height": 4, "depth": .int(depth), "name": "Untitled-1"])
            try s.execute("layer.new.layer")
            let original = try #require(s.active).doc
            let revision = try #require(s.active).revision
            try s.updateActive { $0.savedTo("C:\\作品\\My picture.PSD") }
            let saved = try #require(s.active)
            #expect(saved.doc.name == "My picture.PSD")
            #expect(saved.doc.id == original.id)
            #expect(saved.revision == revision)
            #expect(!saved.isDirty)
            #expect(original.name == "Untitled-1", "the exported snapshot remains immutable")
            let snapshot = saved.doc
            try s.updateActive { $0.savedTo("C:\\作品\\My picture.PSD") }
            #expect(s.active?.doc == snapshot, "saving the same name changes nothing")
            #expect(s.undo())
            #expect(s.active?.doc.name == "My picture.PSD")
            try s.updateActive { $0.savedTo("renamed.psb") }
            #expect(s.redo())
            #expect(s.active?.doc.name == "renamed.psb")
            #expect(s.active?.path == "renamed.psb")
            #expect(s.active?.isDirty == true)
            #expect(s.undo())
            #expect(s.active?.doc.name == "renamed.psb")
        }
    }

    @Test func documentPixelAtTheCoordinateLimits() throws {
        let s = try sessionWithDoc()
        // The last representable column used to panic (its 1x1 rect saturated to empty).
        #expect(try px(s, Int(Int32.max), 0) == [0, 0, 0, 0])
        #expect(try px(s, Int(Int32.min), Int(Int32.max)) == [0, 0, 0, 0])
        // Values beyond i32 used to wrap around onto the canvas (2^32 read column 0).
        do {
            try s.execute("document.pixel", ["x": .int(Int64(1) << 32), "y": 0])
            Issue.record("2^32 was accepted")
        } catch { #expect(isBadParams(error), "\(error)") }
    }

    @Test func fileNewAtTheSizeLimitDoesNotFillEveryTile() throws {
        // A 300000² white background used to fill ~360 GB of tiles before returning (#705).
        for background in ["white", "black", "backgroundColor", "#336699"] {
            let s = Session()
            try s.execute("file.new", ["width": 300_000, "height": 300_000, "background": .string(background)])
            #expect(try px(s, 299_999, 299_999)[3] == 1, "\(background)")
            #expect(try px(s, 0, 0)[3] == 1, "\(background)")
        }
    }

    @Test func commandIdsAreUniqueAndDocumented() {
        var seen = Set<String>()
        let specs = CommandRegistry.standard().specs
        for c in specs {
            #expect(seen.insert(c.id).inserted, "duplicate command id \(c.id)")
            #expect(!c.label.isEmpty, "\(c.id)")
            #expect(c.id.contains("."), "\(c.id) should be namespaced")
        }
        #expect(specs.count > 60)
    }

    @Test func unknownAndDisabledCommandsError() {
        let s = Session()
        #expect(throws: EngineError.unknownCommand("nope.nothing")) { try s.execute("nope.nothing") }
        do {
            try s.execute("layer.new.layer")
            Issue.record("ran without a document")
        } catch {
            if case .disabled? = error as? EngineError {} else { Issue.record("\(error)") }
        }
        #expect(!s.isEnabled("edit.undo"))
    }

    @Test func fileNewTakesWholeFloatsAndSurvivesOddSizes() throws {
        // #254: the New dialog sent `512.0`; it must not fall back to 1920 x 1080.
        let s = Session()
        try s.execute("file.new", ["width": 512.0, "height": 511.6])
        #expect(s.active?.doc.size == PixelSize(width: 512, height: 512))
        #expect(throws: EngineError.self) { try s.execute("file.new", ["width": -5.0, "height": "x"]) }
        #expect(s.active?.doc.size == PixelSize(width: 512, height: 512))
        #expect(s.documents.count == 1)
    }

    @Test func fileNewRejectsInvalidFieldsWithoutChangingTheSession() throws {
        let s = try sessionWithDoc()
        let original = try #require(s.active).doc
        let history = try #require(s.active).history.entries
        let cases: [(String, [JSONValue])] = [
            ("width", [0, -1, 300_001, "32", nil]),
            ("height", [0, -1, 1e30, true]),
            ("resolution", [0, 30000.001, "72", []]),
            ("mode", ["hsv", false, nil]),
            ("depth", [12, "16", -1, 256]),
            ("background", ["#zzzzzz", "#+0+0+0", "##112233", "pink", 42]),
            ("backgroundColor", [[1, 0], [2, 0, 0], "red"]),
            ("name", [false, nil]),
            ("widht", [32]),
        ]
        for (key, values) in cases {
            for value in values {
                do {
                    try s.execute("file.new", .object([key: value]))
                    Issue.record("\(key) = \(value) was accepted")
                } catch {
                    let message = "\(error)"
                    #expect(message.contains("file.new") && message.contains(key), "\(message)")
                }
                #expect(s.documents.count == 1)
                #expect(s.activeIndex == 0)
                #expect(s.active?.doc == original)
                #expect(s.active?.history.entries == history)
            }
        }
    }

    @Test func fileNewKeepsDefaultsAndSupportedModesAndDepths() throws {
        for params: JSONValue in [.object([:]), .null] {
            let s = Session()
            try s.execute("file.new", params)
            let d = try #require(s.active).doc
            #expect(d.size == PixelSize(width: 1920, height: 1080))
            #expect(d.resolutionDpi == 72)
        }
        let modes: [(String, ColorMode)] = [("rgb", .rgb), ("gray", .grayscale), ("grayscale", .grayscale), ("cmyk", .cmyk), ("lab", .lab)]
        let depths: [(Int, SampleType)] = [(8, .u8), (16, .u16), (32, .f32)]
        for (mode, wantMode) in modes {
            for (depth, wantDepth) in depths {
                let s = Session()
                try s.execute("file.new", ["width": 4.0, "height": 3, "mode": .string(mode), "depth": .int(depth), "resolution": 300])
                let d = try #require(s.active).doc
                #expect(d.mode == wantMode)
                #expect(d.depth == wantDepth)
                #expect(d.resolutionDpi == 300)
            }
        }
    }

    @Test func fileNewVariantsPhotocraft() throws {
        let s = Session()
        try s.execute("file.new", ["width": 10, "height": 5, "background": "transparent"])
        #expect(s.active?.doc.layers[0].name == "Layer 1")
        try s.execute("file.new", ["width": 10, "height": 5, "mode": "cmyk", "depth": 16])
        #expect(s.active?.doc.mode == .cmyk)
        #expect(s.active?.doc.depth == .u16)
        try s.execute("file.new", ["background": "#ff0000", "width": 4, "height": 4])
        #expect(try px(s, 1, 1) == [1, 0, 0, 1])
        #expect(s.documents.count == 3)
        try s.execute("file.close")
        #expect(s.documents.count == 2)
    }

    @Test func layerLifecycleWithUndoPhotocraft() throws {
        let s = try sessionWithDoc()
        let id = try newLayer(s)
        #expect(s.active?.activeLayer == id)
        try s.execute("layer.setProps", ["name": "Ink", "opacity": 0.5, "blend": "multiply"])
        let l = try #require(s.active?.doc.layer(id))
        #expect(l.name == "Ink" && l.opacity == 0.5 && l.blend == .multiply)
        try s.execute("layer.duplicate")
        #expect(s.active?.doc.layerCount == 3)
        try s.execute("layer.delete")
        #expect(s.active?.doc.layerCount == 2)
        for _ in 0..<4 { try s.execute("edit.undo") }
        #expect(s.active?.doc.layerCount == 1)
        #expect(!s.isEnabled("edit.undo"))
        try s.execute("edit.redo")
        #expect(s.active?.doc.layerCount == 2)
    }

    @Test func badBlendModeIsAParamError() throws {
        let s = try sessionWithDoc()
        do {
            try s.execute("layer.setProps", ["blend": "sparkle"])
            Issue.record("sparkle accepted")
        } catch { #expect(isBadParams(error), "\(error)") }
    }

    @Test func adjustmentLayersChangeCompositePhotocraft() throws {
        let s = try sessionWithDoc()
        try s.execute("layer.newAdjustmentLayer.invert")
        #expect(try px(s, 3, 3) == [0, 0, 0, 1])
        let doc = try s.execute("document.inspect")
        #expect(doc["layers"]?[0]?["kind"] == "Adjustment")
        #expect(doc["layers"]?[0]?["name"] == "Invert 1")
        try s.execute("layer.setProps", ["visible": false])
        #expect(try px(s, 3, 3) == [1, 1, 1, 1])
    }

    /// #1250 (the Pattern fill rows are in CrossModuleTests): a new adjustment or fill layer made
    /// while a selection is active gets the selection as its layer mask.
    @Test func newAdjustmentAndFillLayersAreMaskedByTheSelection() throws {
        for depth in [8, 16, 32] {
            let rows: [(String, JSONValue, Bool)] = [
                ("layer.newAdjustmentLayer.invert", .object([:]), true),
                ("layer.newAdjustmentLayer.hueSaturation", ["hue": 40, "saturation": 20], false),
                ("layer.newFillLayer.solidColor", ["color": "#000000"], true),
                ("layer.newFillLayer.gradient", ["from": "#000000", "to": "#000000"], true),
            ]
            for (id, params, blackens) in rows {
                let s = Session()
                try s.execute("file.new", ["width": 64, "height": 48, "depth": .int(depth)])
                try s.execute("select.rect", ["x": 8, "y": 8, "width": 16, "height": 16])
                let layer = try layerResult(try s.execute(id, params))
                let d = try #require(s.active)
                let mask = try #require(d.doc.layer(layer)?.mask, "\(id) at \(depth)-bit: no layer mask")
                #expect(mask.value(x: 10, y: 10) == 1, "\(id) at \(depth)-bit: the mask reveals the selected area")
                #expect(mask.value(x: 2, y: 2) == 0, "\(id) at \(depth)-bit: the mask hides outside the selection")
                #expect(mask.linked && mask.enabled, "\(id)")
                #expect(d.doc.selection != nil, "\(id) dropped the selection")
                #expect(try px(s, 2, 2) == [1, 1, 1, 1], "\(id) at \(depth)-bit changed pixels outside the selection")
                if blackens { #expect(try px(s, 10, 10)[..<3] == [0, 0, 0], "\(id) at \(depth)-bit: no effect inside the selection") }
                try s.execute("edit.undo")
                #expect(s.active?.doc.layer(layer) == nil, "\(id): undo keeps the layer")
            }
        }
    }

    @Test func newAdjustmentAndFillLayersHaveWhiteMasksWithoutASelection() throws {
        for depth in [8, 16, 32] {
            let rows: [(String, JSONValue)] = [
                ("layer.newAdjustmentLayer.invert", .object([:])),
                ("layer.newFillLayer.solidColor", ["color": "#000000"]),
                ("layer.newFillLayer.gradient", .object([:])),
            ]
            for (id, params) in rows {
                let s = Session()
                try s.execute("file.new", ["width": 64, "height": 48, "depth": .int(depth)])
                let history = try #require(s.active).history.entries.count
                let layer = try layerResult(try s.execute(id, params))
                let d = try #require(s.active)
                let mask = try #require(d.doc.layer(layer)?.mask, "\(id) at \(depth)-bit: no mask")
                #expect(mask.enabled && mask.linked, "\(id)")
                #expect(mask.surface.tileCount == 0, "a reveal-all mask does not allocate canvas-sized pixels")
                for (x, y): (Int32, Int32) in [(0, 0), (63, 47), (-1, -1), (300_000, 300_000)] {
                    #expect(mask.value(x: x, y: y) == 1, "\(id): the default mask reveals all pixels")
                }
                #expect(d.history.entries.count == history + 1, "the mask belongs to the layer's one history step")
                try s.execute("edit.undo")
                #expect(s.active?.doc.layer(layer) == nil)
                try s.execute("edit.redo")
                #expect(s.active?.doc.layer(layer)?.mask?.value(x: 20, y: 20) == 1)
            }
        }
    }

    @Test func everyAdjustmentCommandRuns() throws {
        let s = try sessionWithDoc()
        let ids = s.registry.specs.filter(\.isAvailable).map(\.id)
            .filter { $0.hasPrefix("layer.newAdjustmentLayer.") || $0.hasPrefix("image.adjustments.") }
        #expect(ids.count >= 28, "\(ids.count)")
        for id in ids {
            // Re-select the background for the destructive ones.
            try s.selectLayer(try #require(s.active).doc.layers[0].id)
            do { try s.execute(id) } catch { Issue.record("\(id): \(error)") }
        }
    }

    @Test func marqueeDraggedPastTheCanvasStopsAtItsEdge() throws {
        let s = try sessionWithDoc() // 64 × 48
        try s.execute("select.rect", ["x": -20, "y": 10, "width": 200, "height": 100])
        #expect(try selectionBounds(s) == [0, 10, 64, 38])
        try s.execute("select.rect", ["x": -30, "y": -30, "width": 200, "height": 200, "ellipse": true])
        #expect(try selectionBounds(s) == [0, 0, 64, 48])
        // Entirely off the canvas: nothing is selected.
        try s.execute("select.rect", ["x": 100, "y": 100, "width": 20, "height": 20])
        #expect(try selectionBounds(s) == .null)
    }

    @Test func marqueeStepsAreNamedAfterTheirTool() throws {
        // #513: the elliptical marquee shares `select.rect` but records its own step name.
        let s = try sessionWithDoc()
        let last = { s.active?.history.undoLabel }
        try s.execute("select.rect", ["x": 0, "y": 0, "width": 20, "height": 10, "ellipse": true])
        #expect(last() == "Elliptical Marquee")
        try s.execute("select.rect", ["x": 0, "y": 0, "width": 20, "height": 10])
        #expect(last() == "Rectangular Marquee")
        // #3031: the Single Row / Single Column Marquee name theirs; an unknown `line` is an error.
        try s.execute("select.rect", ["x": 0, "y": 3, "width": 64, "height": 1, "line": "row"])
        #expect(last() == "Single Row Marquee")
        try s.execute("select.rect", ["x": 3, "y": 0, "width": 1, "height": 48, "line": "column"])
        #expect(last() == "Single Column Marquee")
        #expect(throws: EngineError.self) { try s.execute("select.rect", ["x": 0, "y": 0, "width": 1, "height": 1, "line": "diagonal"]) }
    }

    @Test func selectionModes() throws {
        let s = try sessionWithDoc()
        try s.execute("select.rect", ["x": 0, "y": 0, "width": 10, "height": 10])
        try s.execute("select.rect", ["x": 20, "y": 0, "width": 10, "height": 10, "mode": "add"])
        #expect(try selectionBounds(s) == [0, 0, 30, 10])
        try s.execute("select.rect", ["x": 0, "y": 0, "width": 10, "height": 10, "mode": "subtract"])
        #expect(try selectionBounds(s) == [20, 0, 10, 10])
        try s.execute("select.inverse")
        try s.execute("select.all")
        #expect(try selectionBounds(s) == [0, 0, 64, 48])
        try s.execute("select.rect", ["x": 0, "y": 0, "width": 20, "height": 20, "ellipse": true])
    }

    @Test func clippingMasksApplyToEverySelectedLayer() throws {
        // #1248: with several layers selected, Create Clipping Mask clips all but the lowest (the
        // base) and Release releases them all, each as one history step.
        let s = try sessionWithDoc()
        let ids = try ["A", "B", "C"].map { try newLayer(s, $0) }
        try s.execute("layer.select", ["layer": .id(ids[0])])
        for id in ids[1...] { try s.execute("layer.select", ["layer": .id(id), "mode": "add"]) }
        let clipped = { ids.map { s.active?.doc.layer($0)?.clipped ?? false } }
        let steps = pastCount(s)
        let r = try s.execute("layer.createClippingMask")
        #expect(r["layers"] == .ids([ids[1], ids[2]]))
        #expect(clipped() == [false, true, true], "the lowest selected layer is the base")
        #expect(pastCount(s) == steps + 1)
        try s.execute("layer.releaseClippingMask")
        #expect(clipped() == [false, false, false])
        s.undo()
        #expect(clipped() == [false, true, true], "release is one step")
        // A `layer` param still acts on that layer alone.
        try s.execute("layer.releaseClippingMask", ["layer": .id(ids[2])])
        #expect(clipped() == [false, true, false])
        #expect(throws: EngineError.self) { try s.execute("layer.createClippingMask", ["layer": 999_999]) }
    }

    @Test func arrangeAndGroup() throws {
        let s = try sessionWithDoc()
        let a = try newLayer(s, "A")
        try s.execute("layer.new.layer", ["name": "B"])
        try s.execute("layer.select", ["layer": .id(a)])
        try s.execute("layer.arrange.bringToFront")
        #expect(names(s) == ["Background", "B", "A"])
        #expect(throws: EngineError.self) { try s.execute("layer.arrange.bringForward") }
        try s.execute("layer.groupLayers")
        let doc = try s.execute("document.inspect")
        #expect(doc["layers"]?[0]?["kind"] == "Group")
        #expect(doc["layers"]?[0]?["children"]?[0]?["name"] == "A")
    }

    @Test func imageRotationRotatesEveryLayerNotJustTheActiveOne() throws {
        // Issue #1: Image Rotation must rotate the whole canvas, not only the selected layer.
        let s = Session()
        try s.execute("file.new", ["width": 20, "height": 10, "background": "white"])
        // A second (lower) layer with a red dot at the top-left; keep a third layer active.
        try s.execute("layer.new.layer")
        try s.edit("dot") { doc, a in
            _ = doc.updateLayer(a!) { $0.withRaster { $0.fill(PixelRect(x0: 2, y0: 2, x1: 4, y1: 4), with: [1, 0, 0, 1]) } }
        }
        let dotted = try #require(s.active?.activeLayer)
        try s.execute("layer.new.layer") // a different, empty active layer
        #expect(s.active?.activeLayer != dotted, "active layer is not the dotted one")

        try s.execute("image.imageRotation.180")

        // The non-active layer's content rotated too: (2,2)..(4,4) in 20x10 → (16,6)..(18,8).
        let st = try #require(s.active)
        let surf = try #require(st.doc.layer(dotted)?.surface)
        #expect(surf.rgba(x: 17, y: 6) == SIMD4(1, 0, 0, 1), "dot moved to the opposite corner")
        #expect(surf.rgba(x: 3, y: 3).w == 0, "original spot is now empty")
        // The Background layer rotated as well (still fully opaque white everywhere).
        #expect(st.doc.layers[0].surface?.rgba(x: 1, y: 1) == SIMD4(1, 1, 1, 1))
    }

    @Test func fillLayersAndColors() throws {
        let s = try sessionWithDoc()
        try s.execute("tools.setColors", ["foreground": "#112233"])
        try s.execute("tools.swapColors")
        #expect(s.tools.foreground == SIMD4(1, 1, 1, 1))
        try s.execute("tools.defaultColors")
        try s.execute("layer.newFillLayer.solidColor", ["color": "#ff00ff"])
        #expect(try px(s, 1, 1) == [1, 0, 1, 1])
        try s.execute("layer.newFillLayer.gradient", ["from": "#000000", "to": "#ffffff", "angle": 0])
        let l = try px(s, 0, 10)[0], r = try px(s, 63, 10)[0]
        #expect(l < r)
    }

    @Test func defaultColorsWithMaskTargetedResetsToMaskColors() throws {
        let s = Session()
        s.tools.foreground = SIMD4(0.2, 0.4, 0.6, 1)
        s.tools.background = SIMD4(0.8, 0.6, 0.4, 1)
        _ = s.tools.targetMask(true)
        try s.execute("tools.setColors", ["foreground": "#112233", "background": "#445566"])
        try s.execute("tools.defaultColors")
        #expect(s.tools.foreground == SIMD4(1, 1, 1, 1))
        #expect(s.tools.background == SIMD4(0, 0, 0, 1))
        _ = s.tools.targetMask(false)
        #expect(s.tools.foreground == SIMD4(0.2, 0.4, 0.6, 1))
        #expect(s.tools.background == SIMD4(0.8, 0.6, 0.4, 1))
        try s.execute("tools.defaultColors")
        #expect(s.tools.foreground == SIMD4(0, 0, 0, 1))
        #expect(s.tools.background == SIMD4(1, 1, 1, 1))
    }

    @Test func journalRecordsMutationsOnlyAndReplays() throws {
        let s = try sessionWithDoc()
        try s.execute("document.inspect")
        try s.execute("layer.new.layer", ["name": "x"])
        #expect(s.journal.map(\.id) == ["file.new", "layer.new.layer"])
        // Replaying the journal reproduces the document.
        let replay = Session()
        for inv in s.journal { try replay.execute(inv) }
        #expect(replay.active?.doc.layerCount == s.active?.doc.layerCount)
    }

    @Test func commandListReportsEnablement() throws {
        let s = Session()
        let list = try #require(try s.execute("command.list").arrayValue)
        let find = { (id: String) in list.first { $0["id"] == .string(id) } }
        #expect(find("file.new")?["enabled"] == true)
        #expect(find("layer.new.layer")?["enabled"] == false)
        #expect(find("layer.new.layer")?["needsDocument"] == true)
        #expect(find("file.new")?["needsDocument"] == false)
        #expect(find("file.new")?["disabledReason"] == .null)
        // With a document, a missing selection is not a missing document.
        let s2 = try sessionWithDoc()
        let list2 = try #require(try s2.execute("command.list").arrayValue)
        let deselect = try #require(list2.first { $0["id"] == "select.deselect" })
        #expect(deselect["enabled"] == false && deselect["needsDocument"] == false)
        #expect(deselect["disabledReason"] == "no selection")
    }

    @Test func integerParamsAcceptJSONFloats() throws {
        // UIs send coordinates as floats (e.g. 12.0); every integer parameter must accept them.
        let s = try sessionWithDoc()
        try s.execute("select.rect", ["x": 1.0, "y": 2.0, "width": 10.0, "height": 5.4])
        #expect(try selectionBounds(s) == [1, 2, 10, 5])
        #expect(try s.execute("document.pixel", ["x": 3.0, "y": 3.0]) == [1, 1, 1, 1])
        try s.execute("layer.new.layer")
        try s.execute("layer.translate", ["dx": 2.0, "dy": -1.0])
    }

    @Test func moveToRefusesToNestPastTheGroupDepthCap() throws { try onLargeStack(Self.moveToRefusesToNestPastTheGroupDepthCapBody) }

    static func moveToRefusesToNestPastTheGroupDepthCapBody() throws {
        let s = try sessionWithDoc()
        let deep = try newLayer(s, "Deep")
        for _ in 0..<(maxGroupDepthLimit - 1) { try s.execute("layer.groupLayers", ["layer": .id(deep)]) }
        // `Deep` sits inside MAX - 1 groups. Moving a two-level group (G2 > G1 > Leaf) beside it
        // would put `Leaf` at MAX + 1.
        let path = try #require(s.active?.doc.path(of: deep))
        #expect(path.count - 1 == maxGroupDepthLimit - 1)
        let leaf = try newLayer(s, "Leaf")
        let g1 = try layerResult(try s.execute("layer.groupLayers", ["layer": .id(leaf)]))
        let g = try layerResult(try s.execute("layer.groupLayers", ["layer": .id(g1)]))
        let past = pastCount(s)
        do {
            try s.execute("layer.moveTo", ["layer": .id(g), "target": .id(deep), "position": "above"])
            Issue.record("nested past the cap")
        } catch { #expect("\(error)".contains("deeper than"), "\(error)") }
        #expect(try #require(s.active).doc.maxGroupDepth <= maxGroupDepthLimit)
        #expect(pastCount(s) == past, "no history step recorded")
        // A plain layer beside the deepest one still fits.
        try s.execute("layer.moveTo", ["layer": .id(leaf), "target": .id(deep), "position": "above"])
        #expect(s.active?.doc.maxGroupDepth == maxGroupDepthLimit - 1)
    }

    @Test func moveToReordersAndNests() throws {
        let s = try sessionWithDoc()
        let a = try newLayer(s, "A")
        let b = try newLayer(s, "B")
        let g = try layerResult(try s.execute("layer.new.group", ["name": "G"]))
        // bottom->top: Background, A, B, G ; move A above B
        try s.execute("layer.moveTo", ["layer": .id(a), "target": .id(b), "position": "above"])
        #expect(names(s) == ["Background", "B", "A", "G"])
        try s.execute("layer.moveTo", ["layer": .id(a), "target": .id(g), "position": "into"])
        #expect(names(s) == ["Background", "B", "G"])
        #expect(try s.execute("document.inspect")["layers"]?[0]?["children"]?[0]?["name"] == "A")
        // Groups can't go into themselves.
        #expect(throws: EngineError.self) { try s.execute("layer.moveTo", ["layer": .id(g), "target": .id(a), "position": "into"]) }
        // One undo step.
        try s.execute("edit.undo")
        #expect(names(s) == ["Background", "B", "A", "G"])
    }

    @Test func moveToCopyRejectsBadParams() throws {
        let s = try sessionWithDoc()
        let a = try newLayer(s, "A")
        let past = pastCount(s)
        let bad: [JSONValue] = [
            ["layer": .id(a), "copy": true],
            ["layer": .id(a), "target": "x", "copy": true],
            ["layer": .id(a), "target": 9_999_999, "copy": true],
            ["layer": 9_999_999, "target": .id(a), "copy": true],
            ["layer": .id(a), "target": .id(a), "position": "into", "copy": true],
        ]
        for p in bad { #expect(throws: EngineError.self, "\(p)") { try s.execute("layer.moveTo", p) } }
        #expect(pastCount(s) == past, "no history step recorded")
        #expect(s.active?.doc.layers.count == 2)
    }

    @Test func moveSelectedLayersIntoExistingGroupPreservesOrderSelectionAndOneUndo() throws {
        let s = try sessionWithDoc()
        let a = try newLayer(s, "A")
        let b = try newLayer(s, "B")
        let c = try newLayer(s, "C")
        let g = try layerResult(try s.execute("layer.new.group", ["name": "Existing Group"]))
        try s.execute("layer.select", ["layer": .id(a)])
        try s.execute("layer.select", ["layer": .id(c), "mode": "add"])

        let past = pastCount(s)
        // Pass reversed IDs deliberately. The document order (A below C) must win.
        let r = try s.execute("layer.moveTo", ["layers": .ids([c, a]), "target": .id(g), "position": "into"])
        #expect(r["moved"] == 2)
        let st = try #require(s.active)
        #expect(st.doc.layers.map(\.name) == ["Background", "B", "Existing Group"])
        #expect(st.doc.layer(g)?.children?.map(\.name) == ["A", "C"])
        #expect(st.history.pastCount == past + 1, "one drag = one undo step")
        #expect(st.activeLayer == c, "preserve the active member")
        #expect(st.selectedLayers.contains(a))
        #expect(st.selectedLayers.contains(c))

        try s.execute("edit.undo")
        #expect(names(s) == ["Background", "A", "B", "C", "Existing Group"])
        #expect(s.active?.doc.layer(g)?.children?.isEmpty == true)
        try s.execute("edit.redo")
        #expect(s.active?.doc.layer(g)?.children?.count == 2)
        #expect(b == s.active?.doc.layers[1].id)
    }

    @Test func moveSelectedLayersKeepsSelectedGroupChildrenAndSupportsAboveBelow() throws {
        let s = try sessionWithDoc()
        let a = try newLayer(s, "A")
        let b = try newLayer(s, "B")
        let c = try newLayer(s, "C")
        let group = try layerResult(try s.execute("layer.new.group", ["name": "G"]))
        // Made before B moves into G: a new group goes above the active layer, which would then be inside G.
        let target = try layerResult(try s.execute("layer.new.group", ["name": "Target"]))
        try s.execute("layer.moveTo", ["layer": .id(b), "target": .id(group), "position": "into"])

        let r = try s.execute("layer.moveTo", ["layers": .ids([b, group, a]), "target": .id(target), "position": "into"])
        #expect(r["moved"] == 2, "moving a group already carries its selected child")
        let targetChildren = try #require(s.active?.doc.layer(target)?.children)
        #expect(targetChildren.map(\.name) == ["A", "G"])
        #expect(targetChildren[1].children?[0].id == b)
        #expect(s.active?.selectedLayers.contains(b) == true, "nested selected child is still selected")

        try s.execute("layer.moveTo", ["layers": .ids([group, a]), "target": .id(c), "position": "above"])
        #expect(names(s) == ["Background", "C", "A", "G", "Target"])
        try s.execute("layer.moveTo", ["layers": .ids([group, a]), "target": .id(c), "position": "below"])
        #expect(names(s) == ["Background", "A", "G", "C", "Target"])
    }

    @Test func moveSelectedLayersInvalidTargetsLeaveDocumentAndHistoryUnchanged() throws {
        let s = try sessionWithDoc()
        let a = try newLayer(s, "A")
        let g = try layerResult(try s.execute("layer.new.group", ["name": "G"]))
        try s.execute("layer.moveTo", ["layer": .id(a), "target": .id(g), "position": "into"])
        let outside = try newLayer(s, "Outside")
        let root = try #require(s.active).doc.layers
        let past = pastCount(s)
        let bad: [JSONValue] = [
            ["layers": .ids([g, a]), "target": .id(a), "position": "into"],
            ["layers": .ids([g]), "target": .id(g), "position": "above"],
            ["layers": .ids([g, outside]), "target": .id(g), "position": "into"],
            ["layers": .ids([g, outside]), "target": .id(a), "position": "below"],
            ["layers": .ids([a]), "target": .id(outside), "position": "into"],
            ["layers": .ids([a, a]), "target": .id(outside)],
            ["layers": [.id(a), "bogus"], "target": .id(outside)],
            ["layers": [], "target": .id(outside)],
            ["layers": [.number(Double(UInt64.max))], "target": .id(outside)],
            ["layers": .ids([a]), "target": .id(outside), "position": "sideways"],
        ]
        for p in bad {
            #expect(throws: EngineError.self, "\(p)") { try s.execute("layer.moveTo", p) }
            #expect(pastCount(s) == past, "\(p): no history step")
            #expect(s.active?.doc.layers == root, "\(p): layers unchanged")
        }
    }

    @Test func selectingALayerDoesNotDirtyTheDocument() throws {
        let s = try sessionWithDoc()
        let bg = try #require(s.active).doc.layers[0].id
        #expect(s.active?.isDirty == false)
        try s.execute("layer.select", ["layer": .id(bg)])
        #expect(s.active?.isDirty == false)
        try s.execute("layer.new.layer")
        #expect(s.active?.isDirty == true)
    }

    @Test func coalescedEditsShareOneHistoryStep() throws {
        let s = Session()
        try s.execute("file.new", ["width": 20, "height": 20])
        try s.execute("layer.new.layer")
        let steps = { s.active?.history.entries.count ?? 0 }
        let base = steps()
        for o in [10, 20, 30] { try s.execute("layer.setProps", ["opacity": .number(Double(o) / 100), "coalesce": "drag-1"]) }
        #expect(steps() == base + 1, "three coalesced edits = one step")
        // A different key starts a new step; an uncoalesced edit breaks the chain.
        try s.execute("layer.setProps", ["opacity": 0.4, "coalesce": "drag-2"])
        try s.execute("layer.setProps", ["opacity": 0.5])
        try s.execute("layer.setProps", ["opacity": 0.6, "coalesce": "drag-2"])
        #expect(steps() == base + 4)
        // Undo returns to the state before the whole coalesced run.
        for _ in 0..<4 { s.undo() }
        let st = try #require(s.active)
        let activeId = try #require(st.activeLayer)
        let l = try #require(st.doc.layer(activeId)).opacity
        #expect(abs(l - 1) < 1e-6, "\(l)")
    }

    @Test func movingALayerMovesItsEffectsReferencePoint() throws {
        let s = try sessionWithDoc()
        try s.execute("layer.new.layer")
        try s.edit("ref") { doc, active in _ = doc.updateLayer(active!) { $0.effects.reference = SIMD2(-201, 9) } }
        try s.execute("layer.translate", ["dx": 10, "dy": 5])
        let d = try #require(s.active)
        let activeId = try #require(d.activeLayer)
        #expect(d.doc.layer(activeId)?.effects.reference == SIMD2(-191, 14))
    }

    @Test func marqueeFeatherAndAntiAliasedEllipse() throws {
        let selAt = { (s: Session, x: Int32, y: Int32) -> Float in s.active?.doc.selection?.pixel(x: x, y: y).first ?? 0 }
        // Hard rectangle: fully in or out.
        let s = try sessionWithDoc()
        try s.execute("select.rect", ["x": 10, "y": 10, "width": 20, "height": 20])
        #expect(selAt(s, 10, 20) == 1)
        #expect(selAt(s, 9, 20) == 0)
        // Feather softens only the new shape's edge: partial coverage across the boundary.
        try s.execute("select.rect", ["x": 10, "y": 10, "width": 20, "height": 20, "feather": 3])
        let (inside, edge, outside) = (selAt(s, 20, 20), selAt(s, 10, 20), selAt(s, 8, 20))
        #expect(inside > 0.95 && edge > 0.2 && edge < 0.8 && outside > 0 && outside < edge, "\(inside) \(edge) \(outside)")
        // Anti-aliased ellipse edges have partial coverage; aliased ones don't.
        let partial = { (s: Session) -> Int in
            var n = 0
            for y: Int32 in 0..<48 { for x: Int32 in 0..<64 where (0.01..<0.99).contains(selAt(s, x, y)) { n += 1 } }
            return n
        }
        try s.execute("select.rect", ["x": 5, "y": 5, "width": 40, "height": 30, "ellipse": true])
        #expect(partial(s) > 20)
        try s.execute("select.rect", ["x": 5, "y": 5, "width": 40, "height": 30, "ellipse": true, "antiAlias": false])
        #expect(partial(s) == 0)
    }

    @Test func fileNewResolutionAndBackgroundColor() throws {
        let s = Session()
        s.tools.background = SIMD4(1, 0, 0, 1)
        try s.execute("file.new", ["width": 8, "height": 8, "resolution": 300, "background": "backgroundColor"])
        #expect(s.active?.doc.resolutionDpi == 300)
        let p = try px(s, 2, 2)
        #expect(p[0] > 0.99 && p[1] < 0.01, "\(p)")
    }

    @Test func duplicatingTheBackgroundUnlocksTheCopy() throws {
        let s = try sessionWithDoc()
        try s.execute("layer.duplicate")
        let st = try #require(s.active)
        let activeId = try #require(st.activeLayer)
        let copy = try #require(st.doc.layer(activeId))
        #expect(copy.name == "Background copy")
        #expect(copy.locks == Locks())
        #expect(st.doc.layers[0].locks.transparency)
    }

    @Test func advancedBlendingChannels() throws {
        let s = try sessionWithDoc()
        let id = try newLayer(s)
        try s.execute("layer.setProps", ["channels": [true, true, false]])
        #expect(s.active?.doc.layer(id)?.excludedChannels == 0b100)
        let layer = try #require(s.active?.doc.layer(id))
        let ins = Inspect.layer(layer)
        #expect(ins["channels"] == [true, true, false, true])
        try s.execute("edit.undo")
        #expect(s.active?.doc.layer(id)?.excludedChannels == 0)
    }

    @Test func moveDocumentReordersTabsAndKeepsTheActiveOne() throws {
        let s = Session()
        for name in ["a", "b", "c"] { try s.execute("file.new", ["width": 4, "height": 4, "name": .string(name)]) }
        let docNames = { s.documents.map(\.doc.name) }
        let first = docNames()
        _ = s.setActive(0)
        #expect(s.moveDocument(from: 2, to: 0) == 0)
        #expect(docNames() == [first[2], first[0], first[1]])
        #expect(s.activeIndex == 1, "the active document follows its tab")
        // `to` past the end moves to the last tab; `from` out of range does nothing.
        #expect(s.moveDocument(from: 0, to: 99) == 2)
        #expect(docNames() == first)
        #expect(s.moveDocument(from: 3, to: 0) == nil)
        #expect(docNames() == first)
        #expect(s.activeIndex == 0)
        // The command (for the UI, agents and scripts) moves the active document by default.
        #expect(try s.execute("document.move", ["to": 2]) == ["document": 2])
        #expect(docNames() == [first[1], first[2], first[0]])
        #expect(try s.execute("document.move", ["document": 2, "to": 0]) == ["document": 0])
        #expect(docNames() == first)
        let bad: [JSONValue] = [.object([:]), ["to": -1], ["to": "1"], ["document": 3, "to": 0], ["document": 1.5, "to": 0]]
        for p in bad { #expect(throws: EngineError.self, "\(p)") { try s.execute("document.move", p) } }
        #expect(docNames() == first)
    }

    @Test func documentInspectAndActivateInvalidIndex() throws {
        let s = Session()
        try s.execute("file.new", ["width": 2, "height": 2, "name": "first"])
        try s.execute("file.new", ["width": 2, "height": 2, "name": "second"])
        _ = try s.execute("document.inspect")
        _ = try s.execute("document.inspect", ["document": 0])
        #expect(throws: EngineError.other("no document at index 9")) { try s.execute("document.inspect", ["document": 9]) }
        #expect(throws: EngineError.other("no document at index 9")) { try s.execute("document.activate", ["document": 9]) }
    }

    /// #2166, measured in Photoshop 25.1: a layer mask and the layer pixels keep separate
    /// foreground/background pairs, swapped when the edit target changes.
    @Test func maskAndPixelsKeepTheirOwnColourPair() throws {
        let red = SIMD4<Float>(1, 0, 0, 1), green = SIMD4<Float>(0, 1, 0, 1), blue = SIMD4<Float>(0, 0, 1, 1)
        let (white, black) = ToolState.maskColors
        let s = try sessionWithDoc()
        try s.execute("tools.setColors", ["foreground": "#ff0000", "background": "#0000ff"])
        let pair = { [s.tools.foreground, s.tools.background] }
        let toPixels = s.tools.targetMask(false)
        #expect(!toPixels, "already on the pixels: nothing changes")
        #expect(pair() == [red, blue])
        let toMask = s.tools.targetMask(true)
        #expect(toMask)
        #expect(pair() == [white, black], "a mask starts at white/black")
        let again = s.tools.targetMask(true)
        #expect(!again, "targeting it again changes nothing")
        #expect(pair() == [white, black])
        _ = s.tools.targetMask(false)
        #expect(pair() == [red, blue], "the pixels get their colours back")
        try s.execute("tools.setColors", ["foreground": "#00ff00"])
        _ = s.tools.targetMask(true)
        #expect(pair() == [white, black])
        _ = s.tools.targetMask(false)
        #expect(pair() == [green, blue], "a colour picked on the pixels is remembered")
        // A colour picked while the mask is targeted is remembered for masks.
        _ = s.tools.targetMask(true)
        try s.execute("tools.setColors", ["foreground": "#808080"])
        let maskFg = s.tools.foreground
        #expect(abs(maskFg.x - 0.5) < 0.01)
        _ = s.tools.targetMask(false)
        #expect(pair() == [green, blue])
        _ = s.tools.targetMask(true)
        #expect(pair() == [maskFg, black])
    }

    @Test func deleteLayerSelectsNeighbourAndUndoRestoresLayer() throws {
        for deletedIndex in 0..<3 {
            let s = try sessionWithDoc()
            let ids = try ["bottom", "middle", "top"].map { try newLayer(s, $0) }
            if deletedIndex == 0 {
                let background = try #require(s.active).doc.layers[0].id
                try s.execute("layer.delete", ["layer": .id(background)])
            }
            try s.execute("layer.select", ["layer": .id(ids[deletedIndex])])
            try s.execute("layer.delete")
            let neighbour = deletedIndex == 0 ? ids[1] : ids[deletedIndex - 1]
            #expect(s.active?.activeLayer == neighbour)
            #expect(s.active?.selectedLayerIds == [neighbour])
            #expect(s.active?.doc.layer(ids[deletedIndex]) == nil)
            s.undo()
            #expect(s.active?.doc.layer(ids[deletedIndex]) != nil)
            #expect(s.active?.activeLayer.flatMap { s.active?.doc.layer($0) } != nil)
            s.redo()
            #expect(s.active?.activeLayer == neighbour)
        }
    }

    @Test func deleteMultipleLayersSelectsNextSurvivor() throws {
        let s = try sessionWithDoc()
        let ids = try ["bottom", "middle", "top"].map { try newLayer(s, $0) }
        try s.execute("layer.select", ["layer": .id(ids[1])])
        try s.execute("layer.select", ["layer": .id(ids[2]), "mode": "add"])
        try s.execute("layer.delete")
        #expect(s.active?.activeLayer == ids[0])
        #expect(s.active?.doc.layer(ids[1]) == nil)
        #expect(s.active?.doc.layer(ids[2]) == nil)
        s.undo()
        #expect(s.active?.activeLayer == ids[2])
    }

    @Test func deleteLayerPreservesAnUnaffectedActiveLayerAndLastLayerGuard() throws {
        let s = try sessionWithDoc()
        let background = try #require(s.active?.activeLayer)
        let other = try newLayer(s, "Other")
        try s.execute("layer.delete", ["layer": .id(background)])
        #expect(s.active?.activeLayer == other)
        let before = pastCount(s)
        #expect(throws: EngineError.self) { try s.execute("layer.delete") }
        #expect(s.active?.doc.layerCount == 1)
        #expect(s.active?.activeLayer == other)
        #expect(pastCount(s) == before)
    }
}
