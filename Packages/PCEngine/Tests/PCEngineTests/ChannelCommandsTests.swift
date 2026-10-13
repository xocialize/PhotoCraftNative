// Port of photocraft-engine (crates/engine/src/channel_cmds/tests.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// `edit.fill` (fill_cmds) isn't in this package yet: `fill` below fills the active layer through
// the selection the same way. Tests that need `paint.stroke`, filters, `image.mode.*` or the
// mask-view / vector-mask commands paint or set the state directly, or are skipped (see the end).

import Foundation
import PCDocument
@testable import PCEngine
import PCFoundation
import Testing

@Suite struct ChannelCommandsTests {
    func session(_ depth: Int = 8) throws -> Session {
        let s = Session()
        try s.execute("file.new", ["width": 40, "height": 20, "depth": .int(depth)])
        return s
    }

    func doc(_ s: Session) -> Document { s.active!.doc }
    func view(_ s: Session) -> ChannelView { s.active!.channelView }
    func chan(_ s: Session, _ i: Int, _ x: Int32, _ y: Int32) -> Float { doc(s).channels[i].surface.sampleChannel(x: x, y: y, 0) }
    func selAt(_ s: Session, _ x: Int32, _ y: Int32) -> Float { doc(s).selection?.sampleChannel(x: x, y: y, 0) ?? 0 }
    func px(_ s: Session, _ x: Int32, _ y: Int32) -> [Float] {
        let d = s.active!
        return d.doc.layer(d.activeLayer!)!.surface!.pixel(x: x, y: y)
    }
    func rect(_ s: Session, _ x: Int, _ y: Int, _ w: Int, _ h: Int, _ mode: String = "replace") throws {
        try s.execute("select.rect", ["x": .int(x), "y": .int(y), "width": .int(w), "height": .int(h), "mode": .string(mode)])
    }

    /// Edit › Fill with a colour on the active layer, through the selection.
    func fill(_ s: Session, _ hex: String) throws {
        let c = try #require(Params.parseHex(hex))
        try s.edit("Fill") { doc, active in
            let sel = doc.selection, area = doc.bounds
            doc.withRaster(of: active!) { Pixels.fillSurface(&$0, area, color: c, selection: sel, lockTransparency: false) }
        }
    }

    /// Paints a rectangle of the Quick Mask (what a hard brush stroke on it does).
    func paintQuickMask(_ s: Session, _ r: PixelRect, _ v: Float) throws {
        try s.edit("Brush Tool") { doc, _ in
            guard var q = doc.quickMask else { return }
            q.surface.fill(r, with: [v])
            doc.quickMask = q
        }
    }

    func isPlain(_ v: ChannelView, _ d: Document) -> Bool {
        let colors = Channels.colorCount(d)
        return v.visibleColors(colors) == colors && !d.channels.indices.contains(where: v.alphaShown) && (d.quickMask == nil || v.quickMaskHidden)
            && v.layerMask == nil
    }

    @Test func specsAreDocumentedAndRegistered() {
        var r = CommandRegistry()
        ChannelCommands.register(into: &r)
        #expect(r.count == 28)
        let full = CommandRegistry.standard()
        for sp in r.specs {
            #expect(full.spec(sp.id)?.isAvailable == true, "\(sp.id) not registered")
            #expect(sp.params.hasPrefix("{"), "\(sp.id)")
        }
    }

    @Test func saveSelectionNewAndOperations() throws {
        for depth in [8, 16, 32] {
            let s = try session(depth)
            #expect(throws: EngineError.self, "needs a selection") { try s.execute("select.saveSelection") }
            try rect(s, 0, 0, 10, 20)
            let r = try s.execute("select.saveSelection")
            #expect(r["channel"] == 0)
            #expect(r["name"] == "Alpha 1")
            let d = doc(s)
            #expect(d.channels[0].surface.format == Channels.channelFormat(d))
            #expect(d.channels[0].surface.format.sample == [SampleType.u8, .u16, .f32][[8, 16, 32].firstIndex(of: depth)!])
            #expect(chan(s, 0, 5, 5) == 1)
            #expect(chan(s, 0, 15, 5) == 0)
            // add / subtract / intersect / replace into the existing channel
            try rect(s, 5, 0, 10, 20)
            try s.execute("select.saveSelection", ["channel": 0, "operation": "add"])
            #expect([chan(s, 0, 2, 5), chan(s, 0, 12, 5), chan(s, 0, 20, 5)] == [1, 1, 0])
            try rect(s, 0, 0, 3, 20)
            try s.execute("select.saveSelection", ["channel": 0, "operation": "subtract"])
            #expect([chan(s, 0, 1, 5), chan(s, 0, 5, 5)] == [0, 1])
            try rect(s, 10, 0, 30, 20)
            try s.execute("select.saveSelection", ["channel": "Alpha 1", "operation": "intersect"])
            #expect([chan(s, 0, 5, 5), chan(s, 0, 12, 5)] == [0, 1])
            try s.execute("select.saveSelection", ["channel": 0, "operation": "replace", "name": "Mine"])
            #expect([chan(s, 0, 5, 5), chan(s, 0, 30, 5)] == [0, 1])
            #expect(doc(s).channels[0].name == "Mine")
            #expect(throws: EngineError.self) { try s.execute("select.saveSelection", ["operation": "bogus"]) }
            #expect(throws: EngineError.self) { try s.execute("select.saveSelection", ["channel": 7, "operation": "add"]) }
        }
    }

    @Test func loadSelectionOperationsAndInvert() throws {
        let s = try session()
        try rect(s, 0, 0, 20, 20)
        try s.execute("select.saveSelection")
        try s.execute("select.deselect")
        try s.execute("select.loadSelection", ["channel": 0])
        #expect([selAt(s, 5, 5), selAt(s, 25, 5)] == [1, 0])
        try s.execute("select.loadSelection", ["channel": 0, "invert": true])
        #expect([selAt(s, 5, 5), selAt(s, 25, 5)] == [0, 1])
        try rect(s, 10, 0, 20, 20)
        try s.execute("select.loadSelection", ["channel": 0, "operation": "add"])
        #expect([selAt(s, 5, 5), selAt(s, 25, 5), selAt(s, 35, 5)] == [1, 1, 0])
        try rect(s, 10, 0, 20, 20)
        try s.execute("select.loadSelection", ["channel": 0, "operation": "subtract"])
        #expect([selAt(s, 15, 5), selAt(s, 25, 5)] == [0, 1])
        try rect(s, 10, 0, 20, 20)
        try s.execute("select.loadSelection", ["channel": "Alpha 1", "operation": "intersect"])
        #expect([selAt(s, 15, 5), selAt(s, 25, 5)] == [1, 0])
        #expect(throws: EngineError.self) { try s.execute("select.loadSelection") }
        #expect(throws: EngineError.self) { try s.execute("select.loadSelection", ["channel": 0, "operation": "xor"]) }
        // undo restores the previous selection
        s.undo()
        #expect(selAt(s, 25, 5) == 1)
    }

    @Test func loadTransparencyMaskAndComposite() throws {
        let s = Session()
        try s.execute("file.new", ["width": 20, "height": 10, "background": "transparent"])
        try rect(s, 0, 0, 5, 10)
        try fill(s, "#ffffff")
        try s.execute("select.deselect")
        try s.execute("select.loadSelection", ["channel": "transparency"])
        #expect([selAt(s, 2, 2), selAt(s, 10, 2)] == [1, 0])
        // Composite luminosity: white = selected; transparent over nothing = black.
        try s.execute("select.loadSelection", ["channel": "composite"])
        #expect(selAt(s, 2, 2) > 0.99)
        try s.execute("select.loadSelection", ["channel": "red"])
        #expect(selAt(s, 2, 2) > 0.99)
        // Layer mask
        #expect(throws: EngineError.self) { try s.execute("select.loadSelection", ["channel": "mask"]) }
        try s.execute("layer.layerMask.hideAll")
        try s.execute("select.loadSelection", ["channel": "mask", "invert": true])
        #expect(selAt(s, 10, 5) == 1)
    }

    @Test func channelManagementAndViewState() throws {
        let s = try session()
        let r = try s.execute("channel.new", ["fill": "white", "name": "W"])
        #expect(r["channel"] == 0)
        #expect(chan(s, 0, 3, 3) == 1)
        // A new channel is targeted and shown alone.
        #expect(view(s).target == .alpha(0))
        #expect(view(s).alphaShown(0) && view(s).visibleColors(3) == 0)
        try s.execute("channel.new")
        #expect(doc(s).channels[1].name == "Alpha 1")
        try s.execute("channel.duplicate", ["channel": 0])
        #expect(doc(s).channels[2].name == "W copy")
        try s.execute("channel.duplicate", ["channel": "red", "invert": true])
        #expect(doc(s).channels[3].name == "Red copy")
        #expect(chan(s, 3, 1, 1) == 0, "white image, inverted")
        try s.execute("channel.rename", ["channel": 1, "name": "Renamed"])
        #expect(throws: EngineError.self) { try s.execute("channel.rename", ["channel": 1, "name": " "]) }
        try s.execute("channel.move", ["channel": "Renamed", "to": 0])
        #expect(doc(s).channels.map(\.name) == ["Renamed", "W", "W copy", "Red copy"])
        try s.execute("channel.target", ["channel": 1])
        try s.execute("channel.delete", ["channel": 0])
        #expect(view(s).target == .alpha(0), "target follows its channel")
        try s.execute("channel.delete")
        #expect(view(s).target == .composite)
        #expect(doc(s).channels.count == 2)
        // Visibility toggles (eye) for colour, composite, alpha.
        try s.execute("channel.setVisible", ["channel": "blue", "visible": false])
        #expect(!view(s).colorVisible(2))
        try s.execute("channel.setVisible", ["channel": "composite"])
        #expect(view(s).visibleColors(3) == 3)
        try s.execute("channel.setVisible", ["channel": 1])
        #expect(view(s).alphaShown(1))
        #expect(!isPlain(view(s), doc(s)))
        // Viewing state doesn't dirty or add history.
        let hist = s.active!.history.entries.count
        try s.execute("channel.target", ["channel": "green"])
        #expect(s.active!.history.entries.count == hist)
        let j = try s.execute("channel.list")
        #expect(j["target"]?["kind"] == "color")
        #expect(j["alpha"]?.arrayValue?.count == 2)
        // Undo of the delete brings the channel back; the view stays valid.
        s.undo()
        #expect(doc(s).channels.count == 3)
    }

    @Test func deletingAnEarlierChannelKeepsTheLastChannelTargeted() throws {
        for depth in [8, 16, 32] {
            let s = try session(depth)
            try s.execute("channel.new", ["name": "Remove", "fill": "black"])
            try s.execute("channel.new", ["name": "Keep", "fill": "white"])
            let layerBefore = px(s, 5, 5)
            try s.execute("channel.delete", ["channel": "Remove"])
            #expect(doc(s).channels[0].name == "Keep")
            #expect(view(s).target == .alpha(0), "the surviving target follows its new index")
            #expect(view(s).alphaShown(0))
            #expect(view(s).visibleColors(3) == 0, "keep the channel-only view")
            try s.execute("image.adjustments.invert")
            #expect(chan(s, 0, 5, 5) == 0, "implicit pixel edits still target Keep")
            #expect(px(s, 5, 5) == layerBefore, "the layer must not be edited instead")
            #expect(s.undo())
            #expect(chan(s, 0, 5, 5) == 1)
            #expect(px(s, 5, 5) == layerBefore)
            #expect(s.redo())
            #expect(chan(s, 0, 5, 5) == 0)
            #expect(px(s, 5, 5) == layerBefore)
        }
    }

    @Test func deletingAChannelRemapsAllSurvivingEyesAndTargets() throws {
        for targetIndex in 0..<3 {
            let s = try session()
            for name in ["First", "Middle", "Last"] { try s.execute("channel.new", ["name": .string(name)]) }
            try s.execute("channel.target", ["channel": .int(targetIndex)])
            for (channel, visible) in [false, false, true].enumerated() {
                try s.execute("channel.setVisible", ["channel": .int(channel), "visible": .bool(visible)])
            }
            try s.execute("channel.delete", ["channel": "Middle"])
            let expected: ChannelTarget = [ChannelTarget.alpha(0), .composite, .alpha(1)][targetIndex]
            #expect(view(s).target == expected, "old target \(targetIndex)")
            #expect(!view(s).alphaShown(0))
            #expect(view(s).alphaShown(1), "Last keeps its eye when Middle is removed")
        }
    }

    @Test func everyColourChannelCanHideWhileAlphaStays() throws {
        let s = try session()
        try s.execute("channel.new", ["fill": "white", "name": "Alpha"])
        try s.execute("channel.setVisible", ["channel": "composite", "visible": true])
        #expect(view(s).alphaShown(0))
        #expect(view(s).visibleColors(3) == 3)
        try s.execute("channel.setVisible", ["channel": "composite", "visible": false])
        #expect(view(s).visibleColors(3) == 0, "the RGB eye can turn R, G and B off together")
        #expect(view(s).alphaShown(0), "Alpha stays on")
        try s.execute("channel.setVisible", ["channel": "composite", "visible": true])
        for name in ["red", "green", "blue"] { try s.execute("channel.setVisible", ["channel": .string(name), "visible": false]) }
        #expect(view(s).visibleColors(3) == 0, "R, G and B can each be turned off")
        #expect(view(s).alphaShown(0))
    }

    @Test func quickMaskAndALayerMaskCanBeTheOnlyVisibleChannel() throws {
        let s = try session()
        try fill(s, "#ff0000")
        try s.execute("select.editInQuickMaskMode")
        try s.execute("channel.setVisible", ["channel": "composite", "visible": false])
        #expect(view(s).visibleColors(3) == 0)
        #expect(doc(s).quickMask != nil)
        try s.execute("select.editInQuickMaskMode", ["on": false])
        // Nothing else to show: the colour channels come back.
        try s.execute("channel.setVisible", ["channel": "composite", "visible": false])
        #expect(view(s).visibleColors(3) == 3)

        try s.execute("layer.new.layer")
        try fill(s, "#ff0000")
        try s.execute("layer.layerMask.hideAll")
        for name in ["red", "green", "blue"] { try s.execute("channel.setVisible", ["channel": .string(name), "visible": false]) }
        #expect(view(s).visibleColors(3) == 0, "a transparency mask can be shown alone")
    }

    @Test func shortcutSlotsTargetChannels() throws {
        let s = try session()
        try s.execute("channel.new")
        try s.execute("channel.target.slot3")
        #expect(view(s).target == .color(0))
        try s.execute("channel.target.slot6")
        #expect(view(s).target == .alpha(0))
        #expect(!s.isEnabled("channel.target.slot7"))
        do {
            try s.execute("channel.target.slot7")
            Issue.record("slot 7 ran")
        } catch {
            #expect("\(error)".contains("no channel for ⌘7"), "\(error)")
        }
        try s.execute("channel.target.composite")
        #expect(view(s).target == .composite)
        // Grayscale: ⌘3 is the first alpha channel.
        let g = Session()
        try g.execute("file.new", ["width": 4, "height": 4, "mode": "gray"])
        try g.execute("channel.new")
        try g.execute("channel.target.slot3")
        #expect(g.active?.channelView.target == .alpha(0))
    }

    /// photocraft's version fills and paints (`edit.fill`, `paint.stroke`); Invert goes through
    /// the same restriction hook.
    @Test func singleColourChannelTargetLimitsEdits() throws {
        let s = try session()
        try s.execute("channel.target", ["channel": "red"])
        try s.execute("image.adjustments.invert")
        #expect(px(s, 5, 5) == [0, 1, 1, 1])
        try s.execute("channel.target", ["channel": "blue"])
        try s.execute("image.adjustments.invert")
        #expect(px(s, 20, 10) == [0, 1, 0, 1])
        try s.execute("channel.target", ["channel": "composite"])
        try s.execute("image.adjustments.invert")
        #expect(px(s, 5, 5) == [1, 0, 1, 1])
    }

    @Test func quickMaskEnterPaintExit() throws {
        let s = try session()
        try rect(s, 0, 0, 20, 20)
        try s.execute("select.editInQuickMaskMode")
        let q = try #require(doc(s).quickMask)
        #expect(doc(s).selection == nil)
        #expect([q.surface.sampleChannel(x: 5, y: 5, 0), q.surface.sampleChannel(x: 30, y: 5, 0)] == [1, 0])
        #expect(q.opacity == 0.5 && q.indicates == .maskedAreas)
        // Painting black masks; white unmasks. The layer is untouched.
        let before = px(s, 5, 5)
        try paintQuickMask(s, PixelRect(x0: 3, y0: 3, x1: 7, y1: 7), 0)
        try paintQuickMask(s, PixelRect(x0: 28, y0: 8, x1: 32, y1: 12), 1)
        #expect(px(s, 5, 5) == before)
        try s.execute("select.editInQuickMaskMode")
        #expect(doc(s).quickMask == nil)
        #expect(selAt(s, 5, 5) == 0, "painted black: masked")
        #expect(selAt(s, 12, 12) == 1)
        #expect(selAt(s, 30, 10) == 1, "painted white: selected")
        #expect(selAt(s, 35, 2) == 0)
        // History: enter and exit are steps; undo goes back into Quick Mask with the paint.
        let labels = s.active!.history.entries
        #expect(labels.contains { $0.contains("Edit in Quick Mask") } && labels.contains { $0.contains("Exit Quick Mask") }, "\(labels)")
        s.undo()
        #expect(doc(s).quickMask != nil)
        #expect(doc(s).selection == nil)
        s.redo()
        #expect(doc(s).quickMask == nil)
        #expect(selAt(s, 30, 10) == 1)
    }

    @Test func quickMaskWithoutSelectionAndOptions() throws {
        let s = try session()
        try s.execute("channel.options", ["channel": "quickMask", "color": "#0000ff", "opacity": 30])
        try s.execute("select.editInQuickMaskMode", ["on": true])
        let q = try #require(doc(s).quickMask)
        #expect(q.color == PCColor.rgb(0, 0, 1))
        #expect(abs(q.opacity - 0.3) < 1e-6)
        // Leaving an untouched Quick Mask leaves no selection.
        try s.execute("select.editInQuickMaskMode", ["on": false])
        #expect(doc(s).selection == nil)
        // Painting in Quick Mask edits the mask (photocraft then blurs it with a filter).
        try s.execute("select.editInQuickMaskMode")
        try paintQuickMask(s, PixelRect(x0: 4, y0: 4, x1: 16, y1: 16), 0)
        try s.execute("select.editInQuickMaskMode")
        #expect(selAt(s, 10, 10) < 0.05 && selAt(s, 30, 10) > 0.99)
    }

    func qmOverlay(_ s: Session, _ x: Int32, _ y: Int32) -> Float {
        let q = doc(s).quickMask!
        return q.overlayCoverage(q.surface.sampleChannel(x: x, y: y, 0))
    }

    @Test func quickMaskWithoutSelectionStartsEmptyInBothModes() throws {
        for depth in [8, 16, 32] {
            // Selected Areas set before entering.
            var s = try session(depth)
            try s.execute("channel.options", ["channel": "quickMask", "indicates": "selected"])
            try s.execute("select.editInQuickMaskMode", ["on": true])
            #expect([qmOverlay(s, 5, 5), qmOverlay(s, 35, 15)] == [0, 0], "depth \(depth): no overlay")
            try s.execute("select.editInQuickMaskMode", ["on": false])
            #expect(doc(s).selection == nil, "depth \(depth): untouched → no selection")
            try s.execute("select.editInQuickMaskMode", ["on": true])
            try paintQuickMask(s, PixelRect(x0: 3, y0: 3, x1: 7, y1: 7), 1)
            #expect(qmOverlay(s, 5, 5) > 0.99 && qmOverlay(s, 30, 10) == 0, "depth \(depth)")
            try s.execute("select.editInQuickMaskMode", ["on": false])
            #expect(selAt(s, 5, 5) > 0.99 && selAt(s, 30, 10) == 0, "depth \(depth): painted area is the selection")

            // Selected Areas switched on while in Quick Mask.
            s = try session(depth)
            try s.execute("select.editInQuickMaskMode", ["on": true])
            #expect(qmOverlay(s, 5, 5) == 0, "depth \(depth): Masked Areas, nothing masked yet")
            try s.execute("channel.options", ["channel": "quickMask", "indicates": "selected"])
            #expect([qmOverlay(s, 5, 5), qmOverlay(s, 35, 15)] == [0, 0], "depth \(depth): still no overlay")
            try s.execute("channel.options", ["channel": "quickMask", "indicates": "masked"])
            #expect(qmOverlay(s, 5, 5) == 0, "depth \(depth)")
            try s.execute("select.editInQuickMaskMode", ["on": false])
            #expect(doc(s).selection == nil, "depth \(depth)")
        }
    }

    @Test func quickMaskRoundTripKeepsSelectAll() throws {
        for depth in [8, 16] {
            for indicates in ["masked", "selected"] {
                let s = try session(depth)
                try s.execute("channel.options", ["channel": "quickMask", "indicates": .string(indicates)])
                try s.execute("select.all")
                try s.execute("select.editInQuickMaskMode")
                try s.execute("select.editInQuickMaskMode")
                #expect(doc(s).selection != nil, "depth \(depth) \(indicates): Select All survives")
                #expect([selAt(s, 0, 0), selAt(s, 39, 19)] == [1, 1])
                try s.execute("select.editInQuickMaskMode")
                let other = indicates == "masked" ? "selected" : "masked"
                try s.execute("channel.options", ["channel": "quickMask", "indicates": .string(other)])
                try s.execute("select.editInQuickMaskMode")
                #expect([selAt(s, 0, 0), selAt(s, 39, 19)] == [1, 1], "depth \(depth) \(indicates)→\(other)")
            }
        }
        // A no-selection entry followed by a Select All entry: the second one isn't "no selection".
        let s = try session()
        try s.execute("select.editInQuickMaskMode")
        try s.execute("select.editInQuickMaskMode")
        try s.execute("select.all")
        try s.execute("select.editInQuickMaskMode")
        try s.execute("select.editInQuickMaskMode")
        #expect(selAt(s, 20, 10) == 1)
    }

    @Test func quickMaskOddStatesDontTrap() throws {
        var s = Session()
        #expect(throws: EngineError.self, "no document") { try s.execute("select.editInQuickMaskMode") }
        _ = try? s.execute("channel.options", ["channel": "quickMask", "indicates": "selected"])
        s = try session()
        try s.execute("select.editInQuickMaskMode")
        try s.execute("select.all")
        try s.execute("select.deselect")
        try s.execute("channel.options", ["channel": "quickMask", "indicates": "selected"])
        s.undo()
        s.undo()
        try s.execute("select.editInQuickMaskMode")
    }

    @Test func channelOptionsAndSpotChannels() throws {
        let s = try session()
        try rect(s, 0, 0, 10, 10)
        try s.execute("channel.new", ["fill": "selection"])
        try s.execute("channel.options", ["channel": 0, "name": "Opt", "color": "#00ff00", "opacity": 25, "indicates": "selected"])
        let c = doc(s).channels[0]
        #expect(c.name == "Opt" && c.color == PCColor.rgb(0, 1, 0) && c.indicates == .selectedAreas)
        #expect(abs(c.opacity - 0.25) < 1e-6)
        #expect(c.overlayCoverage(1) == 1)
        try s.execute("channel.options", ["channel": 0, "indicates": "spot", "solidity": 40])
        #expect(doc(s).channels[0].spot?.solidity == 0.4)
        let r = try s.execute("channel.newSpot", ["color": "#ff00ff", "solidity": 100])
        let i = Int(try #require(r["channel"]?.uint64Value))
        #expect(doc(s).channels[i].name == "Spot Color 1")
        #expect(chan(s, i, 5, 5) == 1, "from the selection")
        // Merge spot: flattens and prints the ink (solid magenta) into the image.
        try s.execute("channel.mergeSpot", ["channel": .int(i)])
        #expect(doc(s).layers.count == 1)
        #expect(doc(s).channels.count == 1)
        let p = px(s, 5, 5)
        #expect(abs(p[0] - 1) < 0.01 && p[1] < 0.01 && abs(p[2] - 1) < 0.01, "\(p)")
        #expect(Array(px(s, 20, 15).prefix(3)) == [1, 1, 1])
    }

    @Test func applyImageHandComputed() throws {
        let s = try session()
        // Target: 50% gray. Source: a second document, #ff4000.
        try fill(s, "#808080")
        try s.execute("file.new", ["width": 40, "height": 20])
        try fill(s, "#ff4000")
        _ = s.setActive(0)
        let g: Float = 128.0 / 255.0
        try s.execute("image.applyImage", ["source": ["document": 1], "blending": "multiply"])
        var p = px(s, 3, 3)
        #expect(abs(p[0] - g) < 0.003 && abs(p[1] - g * 64 / 255) < 0.003 && abs(p[2]) < 0.003, "\(p)")
        s.undo()
        // Single source channel applied to every target channel, screen at 50%, inverted.
        try s.execute("image.applyImage", ["source": ["document": 1, "channel": "green", "invert": true], "blending": "screen", "opacity": 50])
        let top: Float = 1 - 64.0 / 255.0
        let screen = 1 - (1 - g) * (1 - top)
        let want = g + (screen - g) * 0.5
        p = px(s, 3, 3)
        #expect(p.prefix(3).allSatisfy { abs($0 - want) < 0.003 }, "\(p) vs \(want)")
        s.undo()
        // Add with scale and offset; masked by an alpha channel; limited to the selection.
        try s.execute("channel.new", ["fill": "white"])
        try s.execute("channel.target", ["channel": "composite"])
        try rect(s, 0, 0, 20, 20)
        try s.execute("image.applyImage", ["source": ["document": 1, "channel": "red"], "blending": "add", "scale": 2, "offset": -10, "mask": ["channel": 0]])
        let want2 = min(max((g + 1) / 2 - 10.0 / 255.0, 0), 1)
        #expect(abs(px(s, 3, 3)[1] - want2) < 0.003)
        #expect(abs(px(s, 30, 3)[1] - g) < 0.003, "outside the selection")
        // Size mismatch is refused.
        try s.execute("file.new", ["width": 5, "height": 5])
        _ = s.setActive(0)
        #expect(throws: EngineError.self) { try s.execute("image.applyImage", ["source": ["document": 2]]) }
        #expect(throws: EngineError.self) { try s.execute("image.applyImage", ["blending": "hue"]) }
    }

    @Test func applyImageOntoTransparentLayer() throws {
        for depth in [8, 16, 32] {
            let s = try session(depth)
            try fill(s, "#c08040")
            let r: Float = 192.0 / 255.0, g: Float = 128.0 / 255.0, b: Float = 64.0 / 255.0
            // An empty layer has no pixels to blend with: it takes the source, whatever the mode.
            try s.execute("layer.new.layer")
            try s.execute("image.applyImage", ["blending": "multiply"])
            var p = px(s, 3, 3)
            #expect(abs(p[0] - r) < 0.003 && abs(p[1] - g) < 0.003 && abs(p[2] - b) < 0.003 && p[3] > 0.999, "depth \(depth): \(p)")
            s.undo()
            // At 50% opacity the empty layer becomes the source at 50% alpha.
            try s.execute("image.applyImage", ["blending": "multiply", "opacity": 50])
            p = px(s, 3, 3)
            #expect(abs(p[0] - r) < 0.003 && abs(p[3] - 0.5) < 0.003, "depth \(depth): \(p)")
            s.undo()
            // Preserve Transparency leaves an empty layer empty.
            try s.execute("image.applyImage", ["blending": "multiply", "preserveTransparency": true])
            #expect(px(s, 3, 3)[3] < 0.001, "depth \(depth)")
        }
    }

    @Test func applyImageIntoAlphaChannel() throws {
        let s = try session()
        try fill(s, "#ffffff")
        try s.execute("channel.new", ["fill": "white"])
        // Targeted channel: Normal blend of the inverted composite → black.
        try s.execute("image.applyImage", ["source": ["channel": "composite", "invert": true], "blending": "normal"])
        #expect(chan(s, 0, 3, 3) < 0.01)
    }

    @Test func calculationsResults() throws {
        let s = try session()
        try rect(s, 0, 0, 20, 20)
        try s.execute("select.saveSelection")
        try rect(s, 10, 0, 20, 20)
        try s.execute("select.saveSelection")
        try s.execute("select.deselect")
        // Multiply = intersection of the two masks.
        let r = try s.execute("image.calculations", ["source1": ["channel": 0], "source2": ["channel": 1], "blending": "multiply", "name": "X"])
        let i = Int(try #require(r["channel"]?.uint64Value))
        #expect(doc(s).channels[i].name == "X")
        #expect([chan(s, i, 5, 5), chan(s, i, 15, 5), chan(s, i, 25, 5)] == [0, 1, 0])
        try s.execute("image.calculations", ["source1": ["channel": 0, "invert": true], "source2": ["channel": 1], "blending": "difference", "result": "selection"])
        // |s2 - (1 - s1)|: x=5: |0-0|=0, x=15: |1-0|=1, x=35: |0-1|=1
        #expect([selAt(s, 5, 5), selAt(s, 15, 5), selAt(s, 35, 5)] == [0, 1, 1])
        let r2 = try s.execute("image.calculations", ["source1": ["channel": "composite"], "source2": ["channel": 1], "blending": "normal", "opacity": 50, "result": "newDocument"])
        #expect(r2["document"] == 1)
        #expect(doc(s).mode == .grayscale)
        let v = doc(s).layers[0].surface!.pixel(x: 5, y: 5)[0]
        #expect(abs(v - 0.5) < 0.01, "\(v)")
        _ = s.setActive(0)
        #expect(throws: EngineError.self) { try s.execute("image.calculations", ["source1": ["channel": 0], "source2": ["channel": 1], "result": "x"]) }
    }

    @Test func splitAndMergeChannels() throws {
        let s = try session()
        try fill(s, "#ff8000")
        try s.execute("channel.new", ["fill": "white", "name": "A"])
        let r = try s.execute("channel.split")
        #expect(r["documents"]?.arrayValue?.count == 4)
        #expect(s.documents.count == 4, "original closed")
        #expect(s.documents.map(\.doc.name) == ["Untitled_R", "Untitled_G", "Untitled_B", "Untitled_A"])
        func v(_ i: Int) -> Float { s.documents[i].doc.layers[0].surface!.pixel(x: 1, y: 1)[0] }
        #expect(v(0) == 1)
        #expect(abs(v(1) - 128.0 / 255.0) < 0.003)
        #expect(v(2) == 0)
        // Merge the three colour docs back.
        _ = s.setActive(0)
        let m = try s.execute("channel.merge", ["mode": "rgb", "documents": [0, 1, 2]])
        #expect(s.documents.count == 2)
        #expect(m["document"] == 1)
        let p = px(s, 1, 1)
        #expect(abs(p[0] - 1) < 0.003 && abs(p[1] - 128.0 / 255.0) < 0.003 && abs(p[2]) < 0.003, "\(p)")
        #expect(throws: EngineError.self) { try s.execute("channel.merge", ["mode": "cmyk"]) }
    }

    @Test func mergeRejectsARepeatedSourceAndKeepsUnrelatedDocuments() throws {
        let s = try session()
        try s.execute("channel.split")
        #expect(s.documents.count == 3)
        try s.execute("file.new", ["width": 40, "height": 20])
        try fill(s, "#00ff00")
        let keep = s.documents[3].doc.id
        let before = s.documents.map(\.doc.id)
        do {
            try s.execute("channel.merge", ["mode": "rgb", "documents": [0, 0, 1]])
            Issue.record("merged a repeated source")
        } catch {
            #expect("\(error)".contains("more than once"), "\(error)")
        }
        #expect(s.documents.map(\.doc.id) == before, "a rejected merge closes nothing")
        #expect(s.setActive(3) && s.undo(), "the unrelated document keeps its history")
        // Distinct indices still merge and close exactly the named sources.
        try s.execute("channel.merge", ["mode": "rgb", "documents": [0, 1, 2]])
        #expect(s.documents.count == 2)
        #expect(s.documents.contains { $0.doc.id == keep })
    }

    @Test func duplicateToOtherDocument() throws {
        let s = try session()
        try rect(s, 0, 0, 5, 5)
        try s.execute("select.saveSelection", ["name": "S"])
        try s.execute("file.new", ["width": 40, "height": 20, "depth": 16])
        _ = s.setActive(0)
        try s.execute("channel.duplicate", ["channel": "S", "document": 1, "name": "S2"])
        let d1 = s.documents[1].doc
        #expect(d1.channels[0].name == "S2")
        #expect(d1.channels[0].surface.format.sample == .u16)
        #expect(d1.channels[0].surface.sampleChannel(x: 2, y: 2, 0) == 1)
        let r = try s.execute("channel.duplicate", ["channel": 0, "document": "new"])
        #expect(s.documents[Int(r["document"]!.uint64Value!)].doc.mode == .grayscale)
    }

    @Test func applyImageAndCalculationsFailGracefullyNeverTrap() throws {
        let s = try session()
        for p: JSONValue in [
            [:], ["source": ["channel": 999]], ["source": ["channel": "nope"]], ["source": ["document": 999]], ["blending": "bogus", "opacity": -50],
        ] {
            _ = try? s.execute("image.applyImage", p)
            _ = try? s.execute("image.calculations", p)
        }
        try s.execute("image.applyImage", ["source": ["channel": "composite"]])
    }

    @Test func channelTargetLayerMaskAndVectorMask() throws {
        let s = try session()
        do { try s.execute("channel.target", ["channel": "mask"]); Issue.record("targeted a missing mask") } catch {
            #expect("\(error)".contains("no layer mask"), "\(error)")
        }
        do { try s.execute("channel.target", ["channel": "vectorMask"]); Issue.record("targeted a missing vector mask") } catch {
            #expect("\(error)".contains("no vector mask"), "\(error)")
        }
        try s.execute("layer.layerMask.revealAll")
        let j = try s.execute("channel.target", ["channel": "mask"])
        #expect(j["target"]?["kind"] == "layerMask")
        #expect(view(s).target == .layerMask)
        #expect(s.tools.maskTargeted)
        // Commands that follow the target edit the mask without an explicit target.
        try s.execute("image.adjustments.invert")
        let lid = s.active!.activeLayer!
        #expect(doc(s).layer(lid)!.mask!.surface.pixel(x: 10, y: 10)[0] == 0, "inverted mask is black")
        let j2 = try s.execute("channel.target", ["channel": "composite"])
        #expect(j2["target"]?["kind"] == "composite")
        #expect(view(s).target == .composite)
        #expect(!s.tools.maskTargeted)
        // #2458: a new adjustment layer, then target its mask.
        try s.execute("layer.newAdjustmentLayer.invert") // photocraft uses Curves (adjust_params, not in this sandbox)
        let ja = try s.execute("channel.target", ["channel": "mask"])
        #expect(ja["target"]?["kind"] == "layerMask")
        // Vector mask targeting (`layer.vectorMask.revealAll` sets an empty path).
        try s.execute("layer.new.layer")
        try s.edit("Add Vector Mask") { doc, active in doc.updateLayer(active!) { $0.vectorMask = VectorMask(path: VectorPath()) } }
        let jv = try s.execute("channel.target", ["channel": "vectorMask"])
        #expect(jv["target"]?["kind"] == "vectorMask")
        #expect(view(s).target == .vectorMask)
    }

    @Test func clearWithAColourChannelTargetedClearsOnlyThatChannel() throws {
        func near(_ a: [Float], _ b: [Float]) -> Bool { a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) < 1e-3 } }
        for duplicate in [false, true] {
            let s = try session(16)
            try rect(s, 0, 0, 20, 20)
            try fill(s, "#336699")
            try s.execute("select.deselect")
            if duplicate { try s.execute("layer.duplicate") }
            let left = px(s, 5, 5), right = px(s, 30, 5)
            s.tools.background = SIMD4(0.8, 0.1, 0.9, 1)
            try s.execute("channel.target", ["channel": "red"])
            try rect(s, 2, 2, 10, 10)
            try s.execute("edit.clear")
            #expect(near(px(s, 5, 5), [0.8, left[1], left[2], 1]), "duplicate \(duplicate): \(px(s, 5, 5))")
            #expect(near(px(s, 15, 5), left), "outside the selection")
            #expect(near(px(s, 30, 5), right))
            s.undo()
            #expect(near(px(s, 5, 5), left), "one undoable step")
        }
    }

    @Test func clearWithAnAlphaChannelOrQuickMaskTargetedFillsItNotTheLayer() throws {
        let s = try session(16)
        let layer = px(s, 5, 5)
        s.tools.background = SIMD4(0, 0, 0, 1)
        try s.execute("channel.new", ["fill": "white"])
        try rect(s, 2, 2, 10, 10)
        try s.execute("edit.clear")
        #expect(chan(s, 0, 5, 5) == 0)
        #expect(chan(s, 0, 15, 5) == 1, "outside the selection")
        #expect(px(s, 5, 5) == layer, "the layer is untouched")
        s.undo()
        #expect(chan(s, 0, 5, 5) == 1, "one undoable step")
        try s.execute("channel.target", ["channel": "composite"])
        try s.execute("select.editInQuickMaskMode", ["on": true])
        try s.execute("edit.clear")
        #expect(doc(s).quickMask!.surface.sampleChannel(x: 5, y: 5, 0) == 0)
        #expect(px(s, 5, 5) == layer, "the layer is untouched in Quick Mask mode")
    }

    @Test func commandBackslashTargetsTheLayerMaskAndCommand2TheComposite() throws {
        let s = try session()
        try s.execute("layer.new.layer")
        #expect(!s.isEnabled("channel.target.layerMask"), "no mask yet")
        #expect(throws: EngineError.self) { try s.execute("channel.target.layerMask") }
        try s.execute("layer.layerMask.revealAll")
        try s.execute("channel.target.composite")
        #expect(s.registry.spec("channel.target.layerMask")?.shortcut == #"Cmd+\"#)
        try s.execute("channel.target.layerMask")
        #expect(view(s).target == .layerMask)
        try s.execute("channel.target.composite")
        #expect(view(s).target == .composite)
    }

    @Test func commandAlt2LoadsTheImagesLuminosity() throws {
        let s = try session()
        try rect(s, 0, 0, 20, 20)
        try fill(s, "#000000")
        try s.execute("select.deselect")
        #expect(s.registry.spec("select.loadLuminosity")?.shortcut == "Cmd+Alt+2")
        try s.execute("select.loadLuminosity")
        #expect(selAt(s, 5, 5) < 0.01, "black: unselected")
        #expect(selAt(s, 30, 5) > 0.99, "white: selected")
    }

    @Test func selectionFromAShapeWithoutPixelCacheUsesItsTransparency() throws {
        for depth in [8, 16, 32] {
            let s = Session()
            try s.execute("file.new", ["width": 100, "height": 80, "depth": .int(depth), "background": "transparent"])
            var shape = ShapeLayer(path: VectorPath([Subpath.polygon([(20, 10), (60, 10), (60, 40), (20, 40)])]), fill: .solid(.rgb(0.8, 0.2, 0.2)))
            shape.cache = nil
            var layer = Layer(name: "Shape", content: .shape(shape))
            layer.visible = false
            layer.opacity = 0.25
            let id = layer.id
            try s.edit("Shape") { doc, _ in doc.layers.append(layer) }
            try s.execute("select.loadSelection", ["channel": "transparency", "layer": .id(id)])
            #expect(selAt(s, 30, 20) > 0.99)
            #expect(selAt(s, 0, 0) < 0.01, "depth \(depth)")
            let b = try #require(doc(s).selection?.contentBounds)
            #expect([b.x0, b.y0, Int32(b.width), Int32(b.height)] == [20, 10, 40, 30])
        }
    }

    @Test func channelsJSONShape() throws {
        let s = try session()
        try s.execute("channel.newSpot", ["name": "Ink", "fromSelection": false])
        let j = try s.execute("channel.list")
        #expect(j["composite"] == "RGB")
        #expect(j["colors"]?.arrayValue?.count == 3)
        #expect(j["alpha"]?[0]?["name"] == "Ink")
        #expect(j["alpha"]?[0]?["spot"]?["solidity"] == 0)
        #expect(j["quickMask"] == .null)
        #expect(j["compositeVisible"] == true)
        #expect(j["layerMaskView"] == .null)
        // `document.inspect` reports the same rows.
        #expect(try s.execute("document.inspect")["channels"] == j)
    }
}

// Skipped photocraft tests: `painting_filtering_and_adjusting_into_an_alpha_channel` (needs
// `paint.stroke`, `paint.bucket` and `filter.blur.gaussianBlur`), `image_size_and_rotate_carry_channels_and_quick_mask`
// (needs `image.mode.bits16`). `single_colour_channel_target_limits_edits`, the Quick Mask paint
// tests and the shape-transparency test are adapted as noted above.
