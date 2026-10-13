// Port of photocraft-engine (crates/engine/src/multichannel_cmds/tests.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Image › Mode › RGB / CMYK / … (color_cmds) isn't in this package yet: the conversions back call
// `MultichannelCommands.convertFrom`, which those commands call for a Multichannel document.

import Foundation
import PCDocument
import PCEngine
import PCFormat
import PCFoundation
import PCPSD
import Testing

@Suite struct MultichannelCommandsTests {
    func session(_ mode: String, _ depth: Int) throws -> Session {
        let s = Session()
        try s.execute("file.new", ["width": 12, "height": 8, "depth": .int(depth), "mode": .string(mode)])
        try s.edit("setup") { doc, active in
            let b = doc.bounds
            doc.withRaster(of: active!) { surf in
                let ch = surf.channels
                var data: [Float] = []
                for y in b.y0..<b.y1 {
                    for x in b.x0..<b.x1 {
                        for c in 0..<(ch - 1) { data.append(Float((Int(x) * 3 + Int(y) * 5 + c * 7) % 16) / 15) }
                        data.append(1)
                    }
                }
                surf.writeRegion(b, data)
            }
        }
        return s
    }

    func doc(_ s: Session) -> Document { s.active!.doc }
    func pixels(_ s: Session) -> [Float] { doc(s).layers[0].surface!.readRegion(doc(s).bounds) }
    func tol(_ depth: Int) -> Float { depth == 8 ? 0.5 / 255 + 1e-6 : 1e-4 }

    func convert(_ s: Session, _ mode: ColorMode) throws -> JSONValue { try MultichannelCommands.convertFrom(s, mode, [:]) }

    @Test func rgbBecomesCMYInksAndBackExactly() throws {
        for depth in [8, 16, 32] {
            let s = try session("rgb", depth)
            let before = pixels(s)
            #expect(s.isEnabled("image.mode.multichannel"))
            let r = try s.execute("image.mode.multichannel")
            #expect(r["channels"] == ["Cyan", "Magenta", "Yellow"])
            let d = doc(s)
            #expect(d.mode == .multichannel)
            #expect(d.layers.isEmpty)
            #expect(MultichannelCommands.inkNames(d) == ["Cyan", "Magenta", "Yellow"])
            // Cyan ink = the red data read as ink.
            let cyan = d.channels[0].surface.pixel(x: 4, y: 3)[0]
            let red = before[(3 * 12 + 4) * 4]
            #expect(abs(cyan - (1 - red)) <= tol(depth), "\(depth): \(cyan) vs \(red)")
            #expect(!s.isEnabled("image.mode.multichannel"), "already multichannel")
            // The display prints the inks: every pixel is opaque.
            let shown = try s.services.renderer.render(doc(s), region: doc(s).bounds)
            #expect(shown.px.allSatisfy { $0.w == 1 })
            let back = try convert(s, .rgb)
            #expect(back["converted"] == "channels")
            #expect(back["mode"] == "rgb")
            #expect(doc(s).mode == .rgb)
            #expect(doc(s).channels.isEmpty)
            let after = pixels(s)
            #expect(after.count == before.count)
            for (a, b) in zip(after, before) { #expect(abs(a - b) <= 2 * tol(depth), "\(depth): \(a) vs \(b)") }
            try s.execute("edit.undo")
            #expect(doc(s).mode == .multichannel)
            try s.execute("edit.undo")
            #expect(doc(s).mode == .rgb)
            #expect(pixels(s) == before)
        }
    }

    @Test func cmykLabAndGrayChannelSets() throws {
        for (mode, back, names) in [("cmyk", ColorMode.cmyk, ["Cyan", "Magenta", "Yellow", "Black"]), ("lab", .lab, ["Alpha 1", "Alpha 2", "Alpha 3"]),
                                    ("grayscale", .grayscale, ["Black"])] {
            for depth in [8, 16] {
                let s = try session(mode, depth)
                let before = pixels(s)
                let r = try s.execute("image.mode.multichannel")
                #expect(r["channels"] == .strings(names), "\(mode)")
                #expect(doc(s).depth == (depth == 8 ? .u8 : .u16))
                _ = try convert(s, back)
                for (a, b) in zip(pixels(s), before) { #expect(abs(a - b) <= 2 * tol(depth), "\(mode)/\(depth): \(a) vs \(b)") }
            }
        }
    }

    @Test func flattensLayersAndKeepsAlphaChannels() throws {
        let s = try session("rgb", 8)
        try s.execute("layer.new.layer")
        try s.execute("select.rect", ["x": 0, "y": 0, "width": 4, "height": 4])
        // Edit › Fill black (fill_cmds) on the new layer.
        try s.edit("Fill") { doc, active in
            let sel = doc.selection, area = doc.bounds
            doc.withRaster(of: active!) { Pixels.fillSurface(&$0, area, color: SIMD4(0, 0, 0, 1), selection: sel, lockTransparency: false) }
        }
        try s.execute("select.saveSelection")
        try s.execute("select.deselect")
        #expect(doc(s).channels.count == 1)
        try s.execute("image.mode.multichannel")
        let d = doc(s)
        #expect(d.channels.count == 4)
        #expect(d.channels[3].spot == nil, "the saved selection stays an alpha channel")
        // The black fill on the upper layer is solid ink in all three plates.
        for k in 0..<3 { #expect(d.channels[k].surface.pixel(x: 1, y: 1)[0] > 0.99) }
        // Back to RGB: the alpha channel survives, the inks become colour channels.
        _ = try convert(s, .rgb)
        #expect(doc(s).channels.count == 1)
        #expect(doc(s).layers[0].surface!.pixel(x: 1, y: 1)[0] < 0.01)
    }

    @Test func mismatchedChannelCountConvertsThePrintedLook() throws {
        let s = try session("rgb", 8)
        try s.execute("image.mode.multichannel")
        // Drop the Yellow plate: two inks can't be RGB channels.
        try s.edit("drop") { doc, _ in doc.channels.removeLast() }
        let shown = try s.services.renderer.render(doc(s), region: doc(s).bounds)
        let r = try convert(s, .rgb)
        #expect(r["converted"] == "appearance")
        let px = doc(s).layers[0].surface!.pixel(x: 5, y: 2)
        let want = shown.px[2 * 12 + 5]
        for c in 0..<3 { #expect(abs(px[c] - want[c]) < 1.0 / 255 + 1e-4) }
    }

    /// photocraft makes the duotone with `image.mode.duotone` (color_cmds); here it is set directly.
    @Test func duotoneInksBecomeChannels() throws {
        let s = try session("grayscale", 8)
        try s.edit("Duotone") { doc, _ in
            doc.mode = .duotone
            doc.duotone = Duotone(inks: [DuotoneInk(name: "Black", color: SIMD3(0, 0, 0)), DuotoneInk(name: "Ink 2", color: SIMD3(0.8, 0.4, 0.1))])
        }
        let r = try s.execute("image.mode.multichannel")
        #expect(r["channels"] == ["Black", "Ink 2"])
    }

    @Test func refusesModesItCantConvert() throws {
        let s = try session("rgb", 8)
        try s.execute("image.mode.multichannel")
        #expect(throws: EngineError.other("a Multichannel document can't be converted to Duotone")) { try convert(s, .duotone) }
        let none = Session()
        #expect(none.disabledReason("image.mode.multichannel") == "no document open")
    }

    // MARK: Files

    @Test func psdRoundTripKeepsNamesInksAndValues() throws {
        for depth in [8, 16] {
            let s = try session("cmyk", depth)
            try s.execute("image.mode.multichannel")
            let d = doc(s)
            let out = try EngineIO.export(d, as: "x.psd", services: s.services)
            let file = try PSDFile(bytes: out.bytes)
            #expect(file.header.colorMode == .multichannel)
            #expect(file.header.channels == 4)
            // Photoshop stores ink as dark: a solid-ink sample is 0.
            let back = try EngineIO.importFile(name: "x.psd", bytes: out.bytes, services: s.services).document
            #expect(back.mode == .multichannel)
            #expect(back.depth == d.depth)
            #expect(back.layers.isEmpty)
            #expect(MultichannelCommands.inkNames(back) == MultichannelCommands.inkNames(d))
            #expect(back.channels.count == d.channels.count)
            for (a, b) in zip(back.channels, d.channels) {
                #expect(a.spot?.color.rgba8 == b.spot?.color.rgba8)
                let (va, vb) = (a.surface.readRegion(d.bounds), b.surface.readRegion(d.bounds))
                #expect(zip(va, vb).allSatisfy { abs($0 - $1) <= tol(depth) }, "\(depth)")
            }
        }
    }

    @Test func psdStoresInkAsDark() throws {
        let s = try session("grayscale", 8)
        try s.execute("edit.fill", ["color": "#000000"])
        try s.execute("image.mode.multichannel")
        let file = try PSDFile(bytes: try EngineIO.export(doc(s), as: "x.psd", services: s.services).bytes)
        let merged = try file.decodeMerged()
        #expect(!merged.isEmpty && merged.allSatisfy { $0 == 0 }, "solid black ink is stored as 0")
    }

    @Test func pcraftRoundTrip() throws {
        let s = try session("rgb", 16)
        try s.execute("image.mode.multichannel")
        let d = doc(s)
        let back = try PcraftFormat.load(try PcraftFormat.save(d))
        #expect(back.mode == .multichannel)
        #expect(back.channels == d.channels)
        let (a, b) = (try s.services.renderer.render(back, region: d.bounds), try s.services.renderer.render(d, region: d.bounds))
        #expect(a.px == b.px)
    }

    @Test func flatExportPrintsTheInks() throws {
        let s = try session("grayscale", 8)
        try s.execute("edit.fill", ["color": "#000000"])
        try s.execute("image.mode.multichannel")
        let out = try EngineIO.export(doc(s), as: "x.png", services: s.services)
        let back = try EngineIO.importFile(name: "x.png", bytes: out.bytes, services: s.services).document
        let px = try s.services.renderer.render(back, region: back.bounds).px[3 * back.size.width + 3]
        // Solid process black ink, not paper.
        #expect(px.x < 0.3 && px.w > 0.99, "\(px)")
    }
}
