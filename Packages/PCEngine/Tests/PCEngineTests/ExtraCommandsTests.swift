// Port of photocraft-engine (crates/engine/src/extra_cmds.rs tests), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Skipped: the crop half of `reveal_all_grows_the_canvas`
// (image.crop is image_cmds'). Adapted: the Quick Mask, alpha channels and the Channels panel target
// are set directly where photocraft runs channel_cmds' commands; a drop shadow is added directly
// (layer_style's command); `layer.layerMask.hideSelection` (not in the core yet) is left out of
// `a_mask_turns_the_background_into_a_layer`; `rasterize_smart_object_layer` uses a smart object
// built with a rendered cache (Convert to Smart Object is smart_cmds'). Added: the type, shape and
// vector-mask rasterize fallbacks.

import Foundation
import PCDocument
@testable import PCEngine
import PCFoundation
import Testing

@Suite struct ExtraCommandsTests {
    func session(_ depth: Int = 8) throws -> Session {
        let s = Session()
        try s.execute("file.new", ["width": 40, "height": 30, "depth": .int(depth)])
        try s.execute("layer.new.layer")
        return s
    }

    func doc(_ s: Session) -> Document { s.active?.doc ?? Document(name: "", size: PixelSize(width: 1, height: 1), mode: .rgb, depth: .u8) }

    func active(_ s: Session) -> Layer? { s.active.flatMap { st in st.activeLayer.flatMap { st.doc.layer($0) } } }

    func pixel(_ s: Session, _ x: Int32, _ y: Int32) -> [Float] { active(s)?.surface?.pixel(x: x, y: y) ?? [] }

    func paintSquare(_ s: Session, _ r: PixelRect, _ c: [Float]) throws {
        try s.edit("paint") { doc, a in
            guard let id = a else { throw EngineError.other("no layer") }
            doc.withRaster(of: id) { $0.fill(r, with: c) }
        }
    }

    func layerId(_ v: JSONValue) throws -> LayerId { LayerId(try #require(v["layer"]?.uint64Value)) }

    /// #935: Equalize, Average and Clouds edit a targeted alpha channel, Quick Mask or layer mask.
    @Test func equalizeAverageAndCloudsEditTheTargetedChannel() throws {
        let cmds = ["image.adjustments.equalize", "filter.blur.average", "filter.render.clouds", "filter.render.differenceClouds"]
        let full = PixelRect(x0: 0, y0: 0, x1: 40, y1: 30)
        for depth in [8, 16, 32] {
            for target in ["quickMask", "alpha", "mask"] {
                for cmd in cmds {
                    let s = try session(depth)
                    s.tools.foreground = SIMD4(0, 0, 0, 1)
                    s.tools.background = SIMD4(1, 1, 1, 1)
                    try s.execute("edit.fill", ["contents": "color", "color": "#808080"])
                    let p: JSONValue
                    switch target {
                    case "quickMask":
                        try s.edit("Quick Mask") { doc, _ in doc.quickMask = AlphaChannel(name: "Quick Mask", surface: Surface(format: Channels.channelFormat(doc))) }
                        p = ["seed": 1]
                    case "alpha":
                        try s.edit("New Channel") { doc, _ in
                            doc.channels.append(AlphaChannel(name: "Alpha 1", surface: Surface(format: Channels.channelFormat(doc), defaultPixel: [1])))
                        }
                        try s.updateActive { $0.channelView.target = .alpha(0) }
                        p = ["seed": 1]
                    default:
                        try s.execute("layer.layerMask.revealAll")
                        p = ["seed": 1, "target": "mask"]
                    }
                    // Two levels in the target, so Equalize and Average have something to change.
                    let editTarget: JSONValue = ["target": target == "alpha" ? ["channel": 0] : .string(target)]
                    try s.edit("levels") { doc, a in
                        try Channels.withTargetSurface(&doc, layer: a, editTarget) { surf, _ in
                            surf.fill(PixelRect(x0: 0, y0: 0, x1: 20, y1: 30), with: [0.4])
                            surf.fill(PixelRect(x0: 20, y0: 0, x1: 40, y1: 30), with: [0.5])
                        }
                    }
                    func read() -> ([Float], [Float]) {
                        let d = doc(s)
                        guard let layer = active(s) else { return ([], []) }
                        let t: [Float]
                        switch target {
                        case "quickMask": t = d.quickMask?.surface.readRegion(full) ?? []
                        case "alpha": t = d.channels.first?.surface.readRegion(full) ?? []
                        default: t = layer.mask?.surface.readRegion(full) ?? []
                        }
                        return (layer.surface?.readRegion(full) ?? [], t)
                    }
                    let (layer0, target0) = read()
                    let past = s.active?.history.pastCount ?? 0
                    try s.execute(cmd, p)
                    let (layer1, target1) = read()
                    let c = "\(cmd) on \(target) at \(depth)"
                    #expect(layer1 == layer0, "\(c): the layer is untouched")
                    #expect(target1 != target0, "\(c): the target changed")
                    #expect(s.active?.history.pastCount == past + 1, "\(c)")
                    s.undo()
                    #expect(read().1 == target0, "\(c): undo restores the target")
                }
            }
        }
    }

    // MARK: Stroke

    @Test func strokeLocationsAtSeveralDepths() throws {
        for depth in [8, 16, 32] {
            for (loc, inside, outside) in [("inside", Float(1), Float(0)), ("outside", 0, 1), ("center", 1, 1)] {
                let s = try session(depth)
                try s.execute("select.rect", ["x": 10, "y": 10, "width": 10, "height": 10])
                try s.execute("edit.stroke", ["width": 2, "color": "#ff0000", "location": .string(loc)])
                #expect(abs(pixel(s, 10, 15)[3] - inside) < 0.02, "\(depth) \(loc) inside \(pixel(s, 10, 15))")
                #expect(abs(pixel(s, 9, 15)[3] - outside) < 0.02, "\(depth) \(loc) outside \(pixel(s, 9, 15))")
                #expect(pixel(s, 15, 15)[3] == 0, "centre untouched")
            }
        }
        // Without a selection the layer's opaque edge is stroked.
        let s = try session(8)
        try paintSquare(s, PixelRect(x0: 10, y0: 10, x1: 20, y1: 20), [0, 0, 1, 1])
        try s.execute("edit.stroke", ["width": 3, "color": "#00ff00", "location": "outside"])
        #expect(pixel(s, 8, 15) == [0, 1, 0, 1])
        #expect(pixel(s, 15, 15) == [0, 0, 1, 1])
    }

    /// Photoshop's Edit › Stroke on a selection: Center puts ceil(w/2) px inside and floor(w/2)
    /// outside, fractional widths round up, and every stroked pixel is fully opaque.
    @Test func strokeWidthsAreWholeOpaquePixelsLikePhotoshop() throws {
        func band(_ loc: String, _ w: Int) -> (Int, Int) {
            switch loc {
            case "inside": (w, 0)
            case "outside": (0, w)
            default: ((w + 1) / 2, w / 2)
            }
        }
        var wrong: [String] = []
        for depth in [8, 16, 32] {
            for loc in ["center", "inside", "outside"] {
                for (param, w) in [(JSONValue.number(1), 1), (2, 2), (3, 3), (4, 4), (5, 5), (0.5, 1), (2.5, 3)] {
                    let s = Session()
                    try s.execute("file.new", ["width": 50, "height": 50, "depth": .int(depth)])
                    try s.execute("layer.new.layer")
                    try s.execute("select.rect", ["x": 10, "y": 10, "width": 20, "height": 20])
                    try s.execute("edit.stroke", ["width": param, "color": "#ff0000", "location": .string(loc)])
                    let (inside, outside) = band(loc, w)
                    for (name, firstIn, inward, horizontal) in [("left", 10, 1, false), ("right", 29, -1, false), ("top", 10, 1, true), ("bottom", 29, -1, true)] {
                        for k in -7..<7 {
                            let c = Int32(firstIn + k * inward)
                            let (x, y) = horizontal ? (Int32(20), c) : (c, Int32(20))
                            let want: Float = (k >= 0 && k < inside) || (k < 0 && -k <= outside) ? 1 : 0
                            let a = pixel(s, x, y)[3]
                            if abs(a - want) > 0.004 { wrong.append("\(depth)-bit \(loc) width \(param.serialized()) \(name) edge, \(k) px: alpha \(a), want \(want)") }
                        }
                    }
                }
            }
        }
        #expect(wrong.isEmpty, "\(wrong.count) pixels differ from Photoshop:\n\(wrong.prefix(40).joined(separator: "\n"))")
    }

    /// Photoshop's 6 px Outside stroke of a 14 px hard circle selection (`#` stroked).
    static let psCircleOutside6 = [
        "..................................", "..................................", "...........############...........",
        "..........##############..........", ".........################.........", "........##################........",
        ".......####################.......", "......######################......", ".....#########......#########.....",
        "....#########........#########....", "....########..........########....", "....#######............#######....",
        "....######..............######....", "....######..............######....", "....######..............######....",
        "....######..............######....", "....######..............######....", "....######..............######....",
        "....#######............#######....", "....########..........########....", "....#########........#########....",
        ".....#########......#########.....", "......######################......", ".......####################.......",
        "........##################........", ".........################.........", "..........##############..........",
        "...........############...........", "..................................", "..................................",
        "..................................",
    ]

    /// Photoshop's 3 px Inside stroke of the same 14 px hard circle.
    static let psCircleInside3 = [
        "...................", "......######.......", ".....########......", "....##########.....", "...####....####....",
        "..####......####...", "..###........###...", "..###........###...", "..###........###...", "..###........###...",
        "..####......####...", "...####....####....", "....##########.....", ".....########......", "......######.......",
        "...................", "...................",
    ]

    /// The selection of a Photoshop sample grid: an Outside stroke's hole, or an Inside stroke's
    /// ring and hole.
    func gridSelection(_ rows: [String], outside: Bool) -> [Float] {
        let (w, h) = (rows[0].count, rows.count)
        var mask = [Float](repeating: 0, count: w * h)
        for (y, row) in rows.enumerated() {
            let b = Array(row.utf8)
            if let first = b.firstIndex(of: UInt8(ascii: "#")), let last = b.lastIndex(of: UInt8(ascii: "#")) {
                for x in first...last where !outside || b[x] == UInt8(ascii: ".") { mask[y * w + x] = 1 }
            }
        }
        return mask
    }

    /// Strokes `mask` as the selection of a `w` × `h` layer and returns its alpha per pixel.
    func strokeAlpha(_ mask: [Float], _ w: Int, _ h: Int, _ depth: Int, _ params: JSONValue) throws -> [Float] {
        let s = Session()
        try s.execute("file.new", ["width": .int(w), "height": .int(h), "depth": .int(depth)])
        try s.execute("layer.new.layer")
        try s.edit("select") { doc, _ in doc.selection = SelectionMath.surface(mask, doc.bounds) }
        try s.execute("edit.stroke", params)
        return (0..<h).flatMap { y in (0..<w).map { x in pixel(s, Int32(x), Int32(y))[3] } }
    }

    @Test func aHardCircleStrokesInsideLikePhotoshop() throws {
        let rows = Self.psCircleInside3
        let (w, h) = (rows[0].count, rows.count)
        let mask = gridSelection(rows, outside: false)
        for depth in [8, 16, 32] {
            let got = try strokeAlpha(mask, w, h, depth, ["width": 3, "color": "#000000", "location": "inside"])
            var wrong: [String] = []
            for (y, row) in rows.enumerated() {
                for (x, c) in row.utf8.enumerated() {
                    let want: Float = c == UInt8(ascii: "#") ? 1 : 0
                    if abs(got[y * w + x] - want) > 0.004 { wrong.append("(\(x), \(y)): \(got[y * w + x]), Photoshop \(want)") }
                }
            }
            #expect(wrong.isEmpty, "\(depth)-bit: \(wrong.count) pixels differ from Photoshop: \(wrong)")
            // A 5 px Inside stroke leaves a plus-shaped hole of 12 pixels; 6 px fills the circle.
            let hole: Set<[Int]> = [[8, 6], [9, 6], [7, 7], [8, 7], [9, 7], [10, 7], [7, 8], [8, 8], [9, 8], [10, 8], [8, 9], [9, 9]]
            let five = try strokeAlpha(mask, w, h, depth, ["width": 5, "color": "#000000", "location": "inside"])
            for (i, m) in mask.enumerated() {
                let stroked = m > 0 && !hole.contains([i % w, i / w])
                #expect((five[i] > 0.996) == stroked, "\(depth)-bit 5 px Inside at (\(i % w), \(i / w))")
            }
            let all = try strokeAlpha(mask, w, h, depth, ["width": 6, "color": "#000000", "location": "inside"])
            for (i, m) in mask.enumerated() { #expect((all[i] > 0.996) == (m > 0), "\(depth)-bit 6 px Inside at (\(i % w), \(i / w))") }
        }
    }

    @Test func aHardCircleStrokesLikePhotoshop() throws {
        let rows = Self.psCircleOutside6
        let (w, h) = (rows[0].count, rows.count)
        let mask = gridSelection(rows, outside: true)
        for depth in [8, 16, 32] {
            let got = try strokeAlpha(mask, w, h, depth, ["width": 6, "color": "#000000", "location": "outside"])
            var wrong: [String] = []
            for (y, row) in rows.enumerated() {
                for (x, c) in row.utf8.enumerated() {
                    let want: Float = c == UInt8(ascii: "#") ? 1 : 0
                    if abs(got[y * w + x] - want) > 0.004 { wrong.append("(\(x), \(y)): \(got[y * w + x]), Photoshop \(want)") }
                }
            }
            #expect(wrong.isEmpty, "\(depth)-bit: \(wrong.count) pixels differ from Photoshop: \(wrong)")
        }
    }

    /// Select All, then Stroke › Inside draws a border around the canvas.
    @Test func strokingASelectionAtTheCanvasEdgeDrawsThatEdge() throws {
        for depth in [8, 16, 32] {
            for (loc, w, inside) in [("inside", 3, 3), ("center", 3, 2), ("center", 1, 1)] {
                let s = try session(depth)
                try s.execute("select.all")
                try s.execute("edit.stroke", ["width": .int(w), "color": "#ff0000", "location": .string(loc)])
                for name in ["left", "right", "top", "bottom"] {
                    for k in Int32(0)..<6 {
                        let (x, y): (Int32, Int32) = switch name {
                        case "left": (k, 15)
                        case "right": (39 - k, 15)
                        case "top": (20, k)
                        default: (20, 29 - k)
                        }
                        let want: Float = k < inside ? 1 : 0
                        let a = pixel(s, x, y)[3]
                        #expect(abs(a - want) < 0.004, "\(depth)-bit \(loc) \(w) px, \(name) side, \(k) px in: alpha \(a), want \(want)")
                    }
                }
            }
        }
    }

    @Test func strokeUsesFillBlendingAndPreservesTransparencyAtEveryDepth() throws {
        for depth in [8, 16, 32] {
            let s = try session(depth)
            try paintSquare(s, PixelRect(x0: 10, y0: 10, x1: 20, y1: 20), [0.5, 0.5, 0.5, 1])
            try s.execute("select.rect", ["x": 10, "y": 10, "width": 10, "height": 10])
            let past = s.active?.history.pastCount ?? 0
            try s.execute("edit.stroke", ["width": 2, "color": "#ffffff", "location": "inside", "mode": "multiply", "opacity": 100, "preserveTransparency": true])
            #expect(s.active?.history.pastCount == past + 1, "Stroke is one history step")
            let edge = pixel(s, 10, 15)
            #expect(abs(edge[0] - 0.5) < 0.015, "\(depth)-bit Multiply must preserve gray: \(edge)")
            #expect(edge[3] == 1)
            try s.execute("edit.stroke", ["width": 2, "color": "#ffffff", "location": "outside", "preserveTransparency": true])
            #expect(pixel(s, 9, 15)[3] == 0, "\(depth)-bit transparency lock prevents new outer pixels")
            try s.execute("edit.stroke", ["width": 2, "color": "#ffffff", "location": "outside", "opacity": 50])
            let out = pixel(s, 9, 15)
            #expect(abs(out[3] - 0.5) < 0.015, "\(depth)-bit 50% stroke opacity: \(out)")
            try s.execute("edit.undo")
            #expect(pixel(s, 9, 15)[3] == 0)
        }
    }

    @Test func strokeRejectsInvalidBlendingOptionsWithoutModifyingTheDocument() throws {
        let s = try session(8)
        try s.execute("select.rect", ["x": 10, "y": 10, "width": 10, "height": 10])
        let past = s.active?.history.pastCount
        for params: JSONValue in [["mode": "unknown-mode"], ["mode": 42], ["mode": "passThrough"], ["opacity": "lots"], ["preserveTransparency": "true"]] {
            #expect(throws: (any Error).self, "\(params.serialized())") { try s.execute("edit.stroke", params) }
            #expect(s.active?.history.pastCount == past, "\(params.serialized()) should not create a history step")
        }
    }

    @Test func transformPresetsAreExact() throws {
        let s = try session(8)
        try paintSquare(s, PixelRect(x0: 10, y0: 10, x1: 20, y1: 14), [1, 0, 0, 1])
        try paintSquare(s, PixelRect(x0: 10, y0: 10, x1: 11, y1: 11), [0, 1, 0, 1])
        try s.execute("edit.transform.flipHorizontal")
        #expect(active(s)?.surface?.contentBounds == PixelRect(x0: 10, y0: 10, x1: 20, y1: 14))
        #expect(pixel(s, 19, 10) == [0, 1, 0, 1])
        try s.execute("edit.transform.flipVertical")
        #expect(pixel(s, 19, 13) == [0, 1, 0, 1])
        try s.execute("edit.transform.rotate180")
        #expect(pixel(s, 10, 10) == [0, 1, 0, 1])
        try s.execute("edit.transform.rotate90Cw")
        let b = try #require(active(s)?.surface?.contentBounds)
        #expect((b.width, b.height) == (4, 10))
        // Top-left corner goes to the top-right after a clockwise turn.
        #expect(pixel(s, b.x1 - 1, b.y0) == [0, 1, 0, 1])
        try s.execute("edit.transform.rotate90Ccw")
        #expect(active(s)?.surface?.contentBounds == PixelRect(x0: 10, y0: 10, x1: 20, y1: 14))
        #expect(pixel(s, 10, 10) == [0, 1, 0, 1])
    }

    /// The presets' ids, labels, menus and params are photocraft's.
    @Test func transformPresetIdsMatchPhotocraft() throws {
        let s = try session(8)
        for id in ["edit.transform.rotate180", "edit.transform.rotate90Cw", "edit.transform.rotate90Ccw", "edit.transform.flipHorizontal", "edit.transform.flipVertical"] {
            let spec = try #require(s.registry.spec(id))
            let pc = try #require(PhotocraftCatalog.byId[id])
            #expect(spec.isAvailable, "\(id)")
            #expect(spec.module == pc.module && spec.label == pc.label && spec.menu == pc.menu && spec.shortcut == pc.shortcut && spec.params == pc.params, "\(id)")
        }
    }

    // MARK: Selection, adjustments, filters

    @Test func reselectRestoresTheLastSelection() throws {
        let s = try session(8)
        #expect(!s.isEnabled("select.reselect"))
        try s.execute("select.rect", ["x": 2, "y": 3, "width": 5, "height": 6])
        try s.execute("select.deselect")
        #expect(doc(s).selection == nil)
        try s.execute("select.reselect")
        #expect(doc(s).selection?.contentBounds == PixelRect(x0: 2, y0: 3, x1: 7, y1: 9))
        #expect(!s.isEnabled("select.reselect"), "nothing to reselect while a selection exists")
    }

    @Test func equalizeSpreadsValues() throws {
        for depth in [8, 16] {
            let s = try session(depth)
            try paintSquare(s, PixelRect(x0: 0, y0: 0, x1: 40, y1: 15), [0.4, 0.4, 0.4, 1])
            try paintSquare(s, PixelRect(x0: 0, y0: 15, x1: 40, y1: 30), [0.5, 0.5, 0.5, 1])
            try s.execute("image.adjustments.equalize")
            let (dark, light) = (pixel(s, 1, 1)[0], pixel(s, 1, 20)[0])
            #expect(dark < 0.05 && light > 0.95, "\(depth): \(dark) \(light)")
        }
    }

    @Test func averageAndClouds() throws {
        let s = try session(8)
        try paintSquare(s, PixelRect(x0: 0, y0: 0, x1: 20, y1: 30), [1, 0, 0, 1])
        try paintSquare(s, PixelRect(x0: 20, y0: 0, x1: 40, y1: 30), [0, 0, 1, 1])
        try s.execute("filter.blur.average")
        let p = pixel(s, 5, 5)
        #expect(abs(p[0] - 0.5) < 0.01 && abs(p[2] - 0.5) < 0.01, "\(p)")
        try s.execute("filter.render.clouds", ["seed": 3])
        let vals = (Int32(0)..<40).map { pixel(s, $0, 12)[0] }
        let (lo, hi) = (vals.min() ?? 0, vals.max() ?? 0)
        #expect(hi - lo > 0.05, "clouds vary: \(lo)..\(hi)")
        #expect(zip(vals, vals.dropFirst()).allSatisfy { abs($0 - $1) < 0.2 }, "clouds are smooth")
        // Difference Clouds over itself with the same seed cancels to black.
        try s.execute("filter.render.differenceClouds", ["seed": 3])
        #expect(pixel(s, 7, 7).prefix(3).allSatisfy { $0 < 0.01 }, "\(pixel(s, 7, 7))")
    }

    @Test func pasteIntoMasksToTheSelection() throws {
        let s = try session(8)
        try paintSquare(s, PixelRect(x0: 0, y0: 0, x1: 10, y1: 10), [1, 0, 0, 1])
        try s.execute("select.all")
        try s.execute("edit.copy")
        let steps = s.active?.history.pastCount ?? 0
        try s.execute("select.rect", ["x": 20, "y": 10, "width": 8, "height": 8])
        try s.execute("edit.pasteSpecial.pasteInto")
        let m = try #require(active(s)?.mask)
        #expect(!m.linked)
        #expect(m.surface.contentBounds == PixelRect(x0: 20, y0: 10, x1: 28, y1: 18))
        #expect(m.value(x: 0, y: 0) == 0)
        #expect(doc(s).selection == nil)
        #expect(s.active?.history.pastCount == steps + 2, "select + one Paste Into step")
        // Paste Outside reveals everything but the selection.
        try s.execute("select.rect", ["x": 20, "y": 10, "width": 8, "height": 8])
        try s.execute("edit.pasteSpecial.pasteOutside")
        let m2 = try #require(active(s)?.mask)
        #expect(m2.value(x: 0, y: 0) == 1 && m2.value(x: 22, y: 12) == 0)
    }

    // MARK: Layers

    @Test func optionClickEyeShowsOneLayerThenRestores() throws {
        let s = try session(8)
        try s.execute("layer.new.layer")
        let ids = doc(s).layers.map(\.id)
        // Background, Layer 1 (hidden beforehand), Layer 2.
        try s.execute("layer.hideLayers", ["layer": .id(ids[1])])
        func vis() -> [Bool] { doc(s).layers.map(\.visible) }
        #expect(try s.execute("layer.showOnly", ["layer": .id(ids[1])])["shownAlone"] == true)
        #expect(vis() == [false, true, false])
        // Another eye moves the solo; the original snapshot survives.
        try s.execute("layer.showOnly", ["layer": .id(ids[2])])
        #expect(vis() == [false, false, true])
        #expect(try s.execute("layer.showOnly", ["layer": .id(ids[2])])["shownAlone"] == false)
        #expect(vis() == [true, false, true], "restored, with Layer 1 still hidden")
        try s.execute("edit.undo")
        #expect(vis() == [false, false, true])
    }

    @Test func showOnlyKeepsGroupsAndTheirContents() throws {
        let s = try session(8)
        try s.execute("layer.new.layer")
        let inner = try #require(active(s)?.id)
        let group = try layerId(try s.execute("layer.groupLayers", ["layer": .id(inner)]))
        func shown() -> [Bool] { doc(s).walk().map(\.layer.visible) }
        // Background, Layer 1, Group 1, Layer 2 (inside the group).
        try s.execute("layer.showOnly", ["layer": .id(inner)])
        #expect(shown() == [false, false, true, true], "the enclosing group stays visible")
        // An undo ends the solo, so the next ⌥-click solos again from the current state.
        try s.execute("edit.undo")
        #expect(try s.execute("layer.showOnly", ["layer": .id(inner)])["shownAlone"] == true)
        try s.execute("edit.undo")
        // Showing a group alone leaves its contents as they are.
        try s.execute("layer.setProps", ["layer": .id(inner), "visible": false])
        try s.execute("layer.showOnly", ["layer": .id(group)])
        #expect(shown() == [false, false, true, false])
        try s.execute("layer.showOnly", ["layer": .id(group)])
        #expect(shown() == [true, true, true, false])
    }

    @Test func showOnlyWithoutASnapshotShowsEveryLayer() throws {
        let s = try session(16)
        let bg = doc(s).layers[0].id
        try s.execute("layer.hideLayers", ["layer": .id(bg)])
        // Layer 1 is already the only visible layer: ⌥-clicking it shows everything.
        #expect(try s.execute("layer.showOnly")["shownAlone"] == false)
        #expect(doc(s).layers.allSatisfy { $0.visible })
        #expect(throws: (any Error).self) { try s.execute("layer.showOnly", ["layer": 9999]) }
        #expect(throws: (any Error).self) { try Session().execute("layer.showOnly") }
    }

    @Test func aMaskTurnsTheBackgroundIntoALayer() throws {
        for (cmd, needsSelection) in [("layer.layerMask.revealAll", false), ("layer.layerMask.hideAll", false), ("layer.layerMask.revealSelection", true)] {
            let s = try session(8)
            let bg = doc(s).layers[0].id
            if needsSelection { try s.execute("select.rect", ["x": 2, "y": 2, "width": 10, "height": 10]) }
            try s.execute(cmd, ["layer": .id(bg)])
            let l = doc(s).layers[0]
            #expect(l.mask != nil && l.name == "Layer 0" && !l.locks.transparency && !l.locks.position, "\(cmd)")
            #expect(!s.isEnabled("layer.new.layerFromBackground"), "\(cmd)")
            #expect(s.undo())
            let l2 = doc(s).layers[0]
            #expect(l2.mask == nil && l2.name == "Background" && l2.locks.transparency, "\(cmd)")
        }
    }

    @Test func hideLayersTogglesOnceEveryTargetIsHidden() throws {
        let s = try session(8)
        try s.execute("layer.new.layer")
        let b = try #require(active(s)?.id)
        func visible() -> Bool { doc(s).layer(b)?.visible ?? false }
        func all() -> [Bool] { LayerMulti.selected(s).map { doc(s).layer($0)?.visible ?? false } }
        try s.execute("layer.hideLayers")
        #expect(!visible())
        try s.execute("layer.hideLayers")
        #expect(visible(), "⌘, again shows it")
        // Several selected: any one still shown means hide them all; then they all come back.
        try s.execute("layer.hideLayers", ["layer": .id(b)])
        try s.execute("select.allLayers")
        #expect(all().count > 1)
        try s.execute("layer.hideLayers")
        #expect(all().allSatisfy { !$0 })
        try s.execute("layer.hideLayers")
        #expect(all().allSatisfy { $0 })
    }

    @Test func slashTogglesLockTransparentPixelsButNotOnTheBackground() throws {
        let s = try session(8)
        let bg = doc(s).layers[0].id
        #expect(doc(s).isBackground(bg))
        try s.execute("layer.new.layer")
        let top = try #require(active(s)?.id)
        func locked(_ id: LayerId) -> Bool { doc(s).layer(id)?.locks.transparency ?? false }
        #expect(try s.execute("layer.toggleLockTransparency")["locked"] == true)
        #expect(locked(top))
        try s.execute("layer.toggleLockTransparency")
        #expect(!locked(top))
        s.undo()
        #expect(locked(top), "one undoable step each")
        let bgLocks = doc(s).layer(bg)?.locks
        #expect(throws: (any Error).self) { try s.execute("layer.toggleLockTransparency", ["layer": .id(bg)]) }
        #expect(doc(s).layer(bg)?.locks == bgLocks, "the Background is left alone")
        #expect(throws: (any Error).self) { try s.execute("layer.toggleLockTransparency", ["layer": 999_999]) }
    }

    @Test func layerUtilities() throws {
        let s = try session(8)
        // Layer from Background.
        #expect(s.isEnabled("layer.new.layerFromBackground"))
        try s.execute("layer.new.layerFromBackground")
        #expect(doc(s).layers[0].name == "Layer 0")
        #expect(!doc(s).layers[0].locks.transparency)
        #expect(!s.isEnabled("layer.new.layerFromBackground"))
        // Copy / paste style and hide all effects (photocraft adds the shadow with layer.layerStyle.dropShadow).
        let first = doc(s).layers[0].id
        try s.edit("Drop Shadow") { doc, _ in doc.updateLayer(first) { $0.effects.items.append(.defaultDropShadow()) } }
        try s.execute("layer.select", ["layer": .id(first)])
        try s.execute("layer.layerStyle.copyLayerStyle")
        let top = doc(s).layers[1].id
        try s.execute("layer.layerStyle.pasteLayerStyle", ["layer": .id(top)])
        #expect(doc(s).layers[1].effects.items.count == 1)
        try s.execute("layer.layerStyle.hideAllEffects")
        #expect(doc(s).walk().allSatisfy { $0.layer.effects.items.isEmpty || !$0.layer.effects.enabled })
        // Mask toggles.
        try s.execute("layer.layerMask.revealAll")
        try s.execute("layer.layerMask.enabled")
        #expect(active(s)?.mask?.enabled == false)
        try s.execute("layer.layerMask.linked", ["linked": false])
        #expect(active(s)?.mask?.linked == false)
        // Hide, delete hidden, delete empty.
        try s.execute("layer.new.layer")
        try s.execute("layer.hideLayers")
        #expect(active(s)?.visible == false)
        #expect(try s.execute("layer.delete.hiddenLayers")["deleted"] == 1)
        try s.execute("layer.new.layer")
        let n = doc(s).layerCount
        #expect(try s.execute("file.scripts.deleteAllEmptyLayers")["deleted"] == 1)
        #expect(doc(s).layerCount == n - 1)
    }

    @Test func ungroupRestoresChildrenInOrder() throws {
        let s = try session(8)
        let a = try #require(active(s)?.id)
        try s.execute("layer.groupLayers")
        #expect(active(s)?.isGroup == true)
        try s.execute("layer.ungroupLayers")
        #expect(s.active?.activeLayer == a)
        #expect(doc(s).layers.allSatisfy { !$0.isGroup })
        #expect(doc(s).layers.count == 2)
    }

    @Test func revealAllBoundsCoverEveryLayer() throws {
        let s = try session(8)
        try paintSquare(s, PixelRect(x0: -5, y0: 0, x1: 10, y1: 10), [1, 0, 0, 1])
        #expect(ExtraCommands.revealAllBounds(doc(s)) == PixelRect(x0: -5, y0: 0, x1: 40, y1: 30))
        let s2 = try session(8)
        #expect(try s2.execute("image.revealAll")["changed"] == false)
    }

    @Test func rasterizeFillAndAllInOneStep() throws {
        let s = try session(8)
        try s.execute("layer.newFillLayer.solidColor", ["color": "#00ff00"])
        try s.execute("layer.newFillLayer.solidColor", ["color": "#0000ff"])
        try s.execute("layer.rasterize.fillContent")
        if case .raster = active(s)?.content {} else { Issue.record("rasterized") }
        #expect(pixel(s, 3, 3) == [0, 0, 1, 1])
        #expect(throws: (any Error).self) { try s.execute("layer.rasterize.type") }
        let steps = s.active?.history.pastCount ?? 0
        #expect(try s.execute("layer.rasterize.allLayers")["rasterized"] == 1)
        #expect(s.active?.history.pastCount == steps + 1)
        #expect(doc(s).walk().allSatisfy { if case .fill = $0.layer.content { false } else { true } })
    }

    @Test func rasterizeSmartObjectLayer() throws {
        let s = try session(8)
        try s.execute("edit.fill", ["contents": "color", "color": "#ff0000"])
        let before = pixel(s, 5, 5)
        // A smart object holding the layer's rendered pixels (as Convert to Smart Object makes it).
        try s.edit("Convert to Smart Object") { doc, active in
            guard let id = active, let surf = doc.layer(id)?.surface else { throw EngineError.other("no pixels") }
            doc.updateLayer(id) { $0.content = .smart(SmartObject(source: .embedded(fileName: "x.png", bytes: []), transform: .identity, cache: surf)) }
        }
        if case .smart = active(s)?.content {} else { Issue.record("a smart object") }
        try s.execute("layer.rasterize.smartObject")
        if case .raster = active(s)?.content {} else { Issue.record("rasterized") }
        #expect(pixel(s, 5, 5) == before)
    }

    @Test func rasterizeShapeTypeAndVectorMaskWithoutTheirModules() throws {
        let s = try session(8)
        let rect = VectorPath([Subpath.polygon([(10, 5), (30, 5), (30, 25), (10, 25)])])
        let shape = try s.edit("New Shape") { doc, active -> LayerId in
            var sh = ShapeLayer(path: rect)
            sh.fill = .solid(.rgb(0, 0, 1))
            let id = doc.insertAbove(active, Layer(name: "Shape 1", content: .shape(sh)))
            active = id
            return id
        }
        let r = try s.execute("layer.rasterize.layer")
        #expect(r["layer"]?.uint64Value == shape.rawValue)
        if case .raster = active(s)?.content {} else { Issue.record("the shape is pixels now") }
        #expect(pixel(s, 20, 15) == [0, 0, 1, 1], "\(pixel(s, 20, 15))")
        #expect(pixel(s, 5, 15)[3] == 0)
        // A vector mask becomes (part of) the layer mask with Rasterize › Layer.
        try s.edit("Vector Mask") { doc, _ in
            doc.updateLayer(shape) { $0.vectorMask = VectorMask(path: VectorPath([Subpath.polygon([(10, 5), (20, 5), (20, 25), (10, 25)])])) }
        }
        try s.execute("layer.rasterize.layer")
        let l = try #require(active(s))
        #expect(l.vectorMask == nil)
        let m = try #require(l.mask)
        #expect(m.value(x: 15, y: 15) > 0.99 && m.value(x: 25, y: 15) < 0.01)
        // Type: whatever the text engine draws, the layer becomes pixels in one step.
        try s.edit("New Type") { doc, active in
            active = doc.insertAbove(active, Layer(name: "Hi", content: .text(TextLayer(text: "Hi", sizePt: 12))))
        }
        try s.execute("layer.rasterize.type")
        if case .raster = active(s)?.content {} else { Issue.record("the type is pixels now") }
        #expect(throws: (any Error).self) { try s.execute("layer.rasterize.type") }
    }
}
