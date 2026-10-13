// Port of photocraft-engine (crates/engine/src/smart_cmds/tests.rs; link_watch.rs tests), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Smart objects end to end: Convert to Smart Object encodes `.pcraft` contents (PCIO), and every
// edit re-renders from them (PCAlgo places them and runs the smart filters). Composites are the
// CPU reference (photocraft-compose), as photocraft's tests use.

import Foundation
import PCAlgo
@testable import PCEngine
import PCDocument
import PCFormat
import PCFoundation
import PCIOSmart
import Testing

/// Shared helpers of the smart-object suites (photocraft's `tests.rs` helpers).
enum SmartFixture {
    static let depths = [8, 16, 32]
    static let W: Int32 = 64
    static let H: Int32 = 48

    static func session(_ depth: Int) throws -> Session {
        let s = Session()
        try s.execute("file.new", ["width": .int(Int(W)), "height": .int(Int(H)), "depth": .int(depth)])
        try s.execute("layer.new.layer")
        return s
    }

    /// Paints a textured block on the active layer, partly outside the canvas (top-left), so
    /// conversion has to keep off-canvas pixels and crop/translate correctly.
    static func paint(_ s: Session) throws {
        try s.edit("setup") { doc, active in
            guard let id = active else { throw EngineError.other("no active layer") }
            doc.withRaster(of: id) { surf in
                let fmt = surf.format
                let r = PixelRect(x0: -6, y0: 5, x1: 40, y1: 38)
                var data: [Float] = []
                for y in r.y0..<r.y1 {
                    for x in r.x0..<r.x1 {
                        let v = Float((x * 7 + y * 13) % 23) / 22
                        let a: Float = (x + y) % 5 == 0 ? 0.5 : 1
                        data += fmt.components(fromRGBA: SIMD4(v, 1 - v, Float((x * y) % 7) / 6, a))
                    }
                }
                surf.writeRegion(r, data)
            }
        }
    }

    static func flat(_ s: Session) throws -> [SIMD4<Float>] {
        let doc = try #require(s.active?.doc)
        return try s.services.renderer.renderCPU(doc, region: doc.bounds).px
    }

    static func maxDiff(_ a: [SIMD4<Float>], _ b: [SIMD4<Float>]) -> Float {
        var m: Float = 0
        for (p, q) in zip(a, b) { for c in 0..<4 { m = Swift.max(m, Swift.abs(p[c] - q[c])) } }
        return m
    }

    static func meanDiff(_ a: [SIMD4<Float>], _ b: [SIMD4<Float>]) -> Float {
        var sum: Float = 0
        for (p, q) in zip(a, b) { for c in 0..<4 { sum += Swift.abs(p[c] - q[c]) } }
        return sum / Float(Swift.max(a.count * 4, 1))
    }

    static func activeSmart(_ s: Session) throws -> SmartObject {
        let d = try #require(s.active)
        let id = try #require(d.activeLayer)
        let l = try #require(d.doc.layer(id))
        guard case .smart(let sm) = l.content else { throw EngineError.other("not smart: \(l.content.kindName)") }
        return sm
    }

    static func smart(_ doc: Document, _ id: LayerId) throws -> SmartObject { try SmartCommands.smart(doc, id) }

    @discardableResult
    static func convert(_ s: Session) throws -> LayerId {
        LayerId(try #require(try s.execute("layer.smartObjects.convertToSmartObject")["layer"]?.uint64Value))
    }

    static func activeLayer(_ s: Session) throws -> Layer {
        let d = try #require(s.active)
        let id = try #require(d.activeLayer)
        return try #require(d.doc.layer(id))
    }

    static func at(_ v: [SIMD4<Float>], _ x: Int32, _ y: Int32) -> SIMD4<Float> { v[Int(y * W + x)] }

    /// A temporary folder.
    static func dir(_ name: String) throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("pcengine-smart-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// A flat document encoded as PNG.
    static func png(_ doc: Document) throws -> [UInt8] { try EngineIO.export(doc, as: "png", services: EngineServices()).bytes }

    static func solid(_ name: String, _ w: Int, _ h: Int, _ c: PCColor) -> Document {
        Document.withBackground(name: name, size: PixelSize(width: w, height: h), mode: .rgb, depth: .u8, fill: c)
    }
}

@Suite struct SmartTests {
    typealias F = SmartFixture

    @Test func conversionIsPixelIdenticalAtEveryDepth() throws {
        for depth in F.depths {
            let s = try F.session(depth)
            try F.paint(s)
            let id = try #require(s.active?.activeLayer)
            try s.edit("opacity") { doc, _ in doc.updateLayer(id) { $0.opacity = 0.6 } }
            let before = try F.flat(s)
            try F.convert(s)
            #expect(F.maxDiff(try F.flat(s), before) == 0, "depth \(depth)")
            let d = try #require(s.active)
            #expect(abs(try F.activeLayer(s).opacity - 0.6) < 1e-6, "opacity stays on the smart layer")
            let sm = try F.activeSmart(s)
            guard case .embedded(let fileName, let bytes) = sm.source else { Issue.record("not embedded"); continue }
            #expect(fileName.hasSuffix(".pcraft"))
            // The nested document is cropped to the content, including the off-canvas part.
            let inner = try SmartCommands.decodeSource(fileName, bytes, services: s.services)
            #expect(inner.size.width == 46 && inner.size.height == 33)
            #expect(inner.depth == d.doc.depth)
            #expect(sm.transform == .translate(-6, 5))
            // Re-rendering from the source reproduces the conversion cache exactly.
            let rendered = try #require(try SmartCommands.render(d.doc, sm, services: s.services))
            let b = PixelRect(x0: -6, y0: 5, x1: 40, y1: 38)
            #expect(rendered.readRegion(b) == sm.cache?.readRegion(b), "depth \(depth)")
            _ = s.undo()
            #expect(try F.flat(s) == before)
        }
    }

    @Test func maskedLayerAndGroupConvertWithinRounding() throws {
        let s = try F.session(8)
        try F.paint(s)
        try s.edit("mask") { doc, active in
            var m = LayerMask.revealAll()
            m.surface.fill(PixelRect(x0: 0, y0: 0, x1: 20, y1: 20), with: [0.3])
            doc.updateLayer(try #require(active)) { $0.mask = m }
        }
        var before = try F.flat(s)
        try F.convert(s)
        #expect(F.maxDiff(try F.flat(s), before) <= 1.0 / 255 + 1e-6)
        // A group converts too (its children move into the nested document).
        try s.execute("layer.new.layer")
        try F.paint(s)
        try s.execute("layer.groupLayers")
        before = try F.flat(s)
        try F.convert(s)
        #expect(F.maxDiff(try F.flat(s), before) <= 1.0 / 255 + 1e-6)
    }

    @Test func patternFillConvertsToEditableSmartObjectWithoutLosingItsPattern() throws {
        let s = try F.session(8)
        try s.execute("layer.newFillLayer.pattern", ["pattern": "Bricks"])
        let before = try F.flat(s)
        let patternId = try #require(s.active?.doc.patterns.first?.id)
        #expect(before.contains { $0.w > 0 }, "the pattern fill is visible")
        try F.convert(s)
        #expect(F.maxDiff(try F.flat(s), before) < 1e-6, "conversion keeps every pattern pixel")
        let sm = try F.activeSmart(s)
        guard case .embedded(let fileName, let bytes) = sm.source else { Issue.record("not embedded"); return }
        let inner = try SmartCommands.decodeSource(fileName, bytes, services: s.services)
        #expect(inner.patterns.contains { $0.id == patternId }, "the embedded source keeps the pattern resource")
        // The smart object's source remains live after opening and editing its contents.
        let child = try #require(try s.execute("layer.smartObjects.editContents")["document"]?.uint64Value)
        #expect(s.activeIndex == Int(child))
        #expect(s.active?.doc.patterns.contains { $0.id == patternId } == true)
        _ = s.setActive(0)
        #expect(F.maxDiff(try F.flat(s), before) < 1e-6)
        _ = s.undo()
        #expect(F.maxDiff(try F.flat(s), before) < 1e-6)
    }

    @Test func emptyLayerCannotBeConverted() throws {
        let s = try F.session(8)
        #expect(throws: (any Error).self) { try s.execute("layer.smartObjects.convertToSmartObject") }
    }

    @Test func smartFiltersAreReEditable() throws {
        for depth in [8, 16] {
            let s = try F.session(depth)
            try F.paint(s)
            let original = try F.flat(s)
            try s.execute("filter.convertForSmartFilters")
            #expect(!s.isEnabled("filter.convertForSmartFilters"), "already smart")
            try s.execute("filter.blur.gaussianBlur", ["radius": 2])
            let r2 = try F.flat(s)
            #expect(F.maxDiff(r2, original) > 0.05)
            let sm = try F.activeSmart(s)
            #expect(sm.smartFilters.count == 1)
            guard case .embedded(_, let bytes) = sm.source else { Issue.record("not embedded"); return }
            // Change the radius: the result comes from the source, not from the blurred pixels.
            try s.execute("layer.smartFilter.setParams", ["index": 0, "params": ["radius": 6]])
            let r6 = try F.flat(s)
            #expect(F.maxDiff(r6, r2) > 0.01)
            try s.execute("layer.smartFilter.setParams", ["params": ["radius": 2]])
            #expect(F.maxDiff(try F.flat(s), r2) < 1e-6, "same params, same pixels")
            // Hiding the filter shows the original exactly.
            try s.execute("layer.smartFilter.setVisible", ["index": 0])
            #expect(try F.flat(s) == original)
            #expect(try F.activeSmart(s).smartFilters[0].visible == false)
            _ = s.undo()
            #expect(F.maxDiff(try F.flat(s), r2) < 1e-6)
            _ = s.redo()
            #expect(try F.flat(s) == original)
            // All of that decoded the contents at most once (the conversion seeded the cache).
            #expect(SmartCommands.sourceDecodeCount(bytes, try #require(s.active?.doc.pixelFormat)) <= 1)
        }
    }

    @Test func filterStackOrderBlendDisableAndClear() throws {
        let s = try F.session(8)
        try F.paint(s)
        let original = try F.flat(s)
        try F.convert(s)
        try s.execute("filter.other.offset", ["horizontal": 5, "undefinedAreas": "transparent"])
        try s.execute("filter.blur.gaussianBlur", ["radius": 3])
        let ab = try F.flat(s)
        try s.execute("layer.smartFilter.move", ["index": 1, "to": 0])
        #expect(try F.activeSmart(s).smartFilters[0].command == "filter.blur.gaussianBlur")
        #expect(F.maxDiff(try F.flat(s), ab) > 1e-3, "order matters")
        _ = s.undo()
        #expect(try F.flat(s) == ab)
        // 0 % opacity on both filters = original.
        try s.execute("layer.smartFilter.blendingOptions", ["index": 0, "opacity": 0])
        try s.execute("layer.smartFilter.blendingOptions", ["index": 1, "opacity": 0, "blend": "multiply"])
        #expect(F.maxDiff(try F.flat(s), original) < 1e-6)
        #expect(try F.activeSmart(s).smartFilters[1].blend == .multiply)
        #expect(throws: (any Error).self) { try s.execute("layer.smartFilter.blendingOptions", ["blend": "nope"]) }
        _ = s.undo()
        _ = s.undo()
        try s.execute("layer.smartFilter.disableSmartFilters")
        #expect(try F.flat(s) == original)
        #expect(try F.activeSmart(s).filtersEnabled == false)
        try s.execute("layer.smartFilter.disableSmartFilters")
        #expect(try F.flat(s) == ab)
        try s.execute("layer.smartFilter.delete", ["index": 0])
        #expect(try F.activeSmart(s).smartFilters.count == 1)
        #expect(throws: (any Error).self) { try s.execute("layer.smartFilter.delete", ["index": 5]) }
        try s.execute("layer.smartFilter.clearSmartFilters")
        #expect(try F.flat(s) == original)
        #expect(!s.isEnabled("layer.smartFilter.clearSmartFilters"))
    }

    /// Issue #466: an explicit `layer` target is checked instead of the active layer, which stays
    /// active; without one the commands still follow the active layer (menus).
    @Test func smartFilterCommandsCheckAnExplicitLayerTarget() throws {
        let s = try F.session(8)
        try F.paint(s)
        let so = try F.convert(s)
        try s.execute("filter.sharpen.smartSharpen", ["amount": 65, "radius": 1])
        let curves = LayerId(try #require(try s.execute("layer.newAdjustmentLayer.curves", ["points": [[0, 0], [255, 255]]])["layer"]?.uint64Value))
        func active() -> LayerId? { s.active?.activeLayer }
        #expect(active() == curves)
        func filter() throws -> SmartFilter {
            let doc = try #require(s.active?.doc)
            return try #require(try F.smart(doc, so).smartFilters.first)
        }
        // No target: the active Curves layer decides, as the menu shows.
        #expect(!s.isEnabled("layer.smartFilter.setParams"))
        do {
            try s.execute("layer.smartFilter.setParams", ["params": ["amount": 80]])
            Issue.record("disabled without a smart object target")
        } catch EngineError.disabled {}
        let r = try s.execute("layer.smartFilter.setParams", ["layer": .id(so), "index": 0, "params": ["amount": 80]])
        #expect(r == ["layer": .id(so)])
        #expect(try filter().params["amount"] == 80)
        try s.execute("layer.smartFilter.setVisible", ["layer": .id(so), "visible": false])
        #expect(try filter().visible == false)
        #expect(active() == curves, "the active layer stays")
        // A target that isn't a smart object with filters is still refused, and the active layer stays.
        do {
            try s.execute("layer.smartFilter.setParams", ["layer": .id(curves), "params": [:]])
            Issue.record("a Curves target is refused")
        } catch EngineError.disabled {}
        #expect(throws: (any Error).self) { try s.execute("layer.smartFilter.setParams", ["layer": 999_999, "params": [:]]) }
        #expect(active() == curves)
    }

    @Test func selectionBecomesTheFilterMask() throws {
        let s = try F.session(8)
        try F.paint(s)
        let original = try F.flat(s)
        try F.convert(s)
        try s.execute("select.rect", ["x": 0, "y": 0, "width": 16, "height": 48])
        try s.execute("filter.blur.gaussianBlur", ["radius": 3])
        #expect(try F.activeSmart(s).filterMask != nil)
        let px = try F.flat(s)
        #expect(F.at(px, 30, 20) == F.at(original, 30, 20), "outside the mask: unfiltered")
        #expect(F.at(px, 6, 20) != F.at(original, 6, 20), "inside the mask: filtered")
        try s.execute("layer.smartFilter.disableFilterMask")
        #expect(F.at(try F.flat(s), 30, 20) != F.at(original, 30, 20))
        try s.execute("layer.smartFilter.deleteFilterMask")
        #expect(try F.activeSmart(s).filterMask == nil)
        #expect(!s.isEnabled("layer.smartFilter.deleteFilterMask"))
    }

    /// Scales `id` to 10 % around the origin and back, returning the composite.
    func shrinkAndGrow(_ s: Session, _ id: LayerId) throws -> [SIMD4<Float>] {
        try s.execute("edit.transform", ["layer": .id(id), "matrix": [0.1, 0, 0, 0.1, 0, 0]])
        try s.execute("edit.transform", ["layer": .id(id), "matrix": [10, 0, 0, 10, 0, 0]])
        return try F.flat(s)
    }

    @Test func transformsReRenderFromSourceLosslessly() throws {
        let raster = try F.session(8)
        try F.paint(raster)
        let original = try F.flat(raster)
        let rasterResult = try shrinkAndGrow(raster, try #require(raster.active?.activeLayer))

        let smart = try F.session(8)
        try F.paint(smart)
        let sid = try F.convert(smart)
        // Scaled down, the smart object really is small...
        try smart.execute("edit.transform", ["layer": .id(sid), "matrix": [0.1, 0, 0, 0.1, 0, 0]])
        let small = try #require(try F.activeSmart(smart).cache).contentBounds
        #expect(small.width <= 7, "\(small)")
        // ...and scaled back up it is the original again.
        try smart.execute("edit.transform", ["layer": .id(sid), "matrix": [10, 0, 0, 10, 0, 0]])
        let smartResult = try F.flat(smart)
        let (es, er) = (F.meanDiff(smartResult, original), F.meanDiff(rasterResult, original))
        #expect(es < 1e-6, "smart error \(es)")
        #expect(er > 0.02, "raster error \(er)")
        // A non-integer move re-renders with bicubic; moving back is exact again.
        try smart.execute("edit.transform", ["layer": .id(sid), "matrix": [1, 0, 0, 1, 0.5, 0.25]])
        #expect(F.maxDiff(try F.flat(smart), original) > 0.01)
        try smart.execute("edit.transform", ["layer": .id(sid), "matrix": [1, 0, 0, 1, -0.5, -0.25]])
        #expect(F.maxDiff(try F.flat(smart), original) < 1e-6)
        // Whole-pixel moves (Move tool) shift without re-rendering.
        try smart.execute("layer.translate", ["dx": 3, "dy": -2])
        #expect(try F.activeSmart(smart).transform == .translate(-3, 3))
        // Perspective keeps the full projective placement (and stays a smart object).
        try smart.execute("edit.transform", ["layer": .id(sid), "quad": [[0, 0], [10, 0], [12, 10], [-2, 10]]])
        #expect(try F.activeSmart(smart).perspective != nil)
    }

    @Test func filtersFollowTransforms() throws {
        let s = try F.session(16)
        try F.paint(s)
        let id = try F.convert(s)
        try s.execute("filter.blur.gaussianBlur", ["radius": 2])
        let blurred = try F.flat(s)
        try s.execute("edit.transform", ["layer": .id(id), "matrix": [2, 0, 0, 2, 0, 0]])
        #expect(try F.activeSmart(s).smartFilters.count == 1)
        try s.execute("edit.transform", ["layer": .id(id), "matrix": [0.5, 0, 0, 0.5, 0, 0]])
        #expect(F.maxDiff(try F.flat(s), blurred) < 1e-6, "filter re-applied to the re-rendered source")
    }

    func paintChild(_ s: Session, _ c: SIMD4<Float>) throws {
        try s.edit("paint") { doc, _ in
            let id = try #require(doc.layers.first?.id)
            let fmt = doc.pixelFormat
            doc.withRaster(of: id) { $0.fill(PixelRect(x0: 0, y0: 0, x1: 46, y1: 33), with: fmt.components(fromRGBA: c)) }
        }
    }

    @Test func editContentsUpdatesTheParent() throws {
        let s = try F.session(8)
        try F.paint(s)
        let id = try F.convert(s)
        let before = try F.flat(s)
        let child = Int(try #require(try s.execute("layer.smartObjects.editContents")["document"]?.uint64Value))
        #expect(s.activeIndex == child)
        #expect(s.isEnabled("layer.smartObjects.saveContents"))
        // Paint the nested document's layer solid red.
        try paintChild(s, SIMD4(1, 0, 0, 1))
        try s.execute("layer.smartObjects.saveContents")
        #expect(s.active?.isDirty == false)
        _ = s.setActive(0)
        let after = try F.flat(s)
        #expect(F.at(after, 10, 20) == SIMD4(1, 0, 0, 1))
        #expect(after != before)
        _ = s.undo()
        #expect(try F.flat(s) == before, "the update is one undoable step in the parent")
        _ = s.redo()
        // Editing the same smart object again switches to the open document, no second copy.
        let open = s.documents.count
        let again = try s.execute("layer.smartObjects.editContents")
        #expect(again["document"]?.uint64Value == UInt64(child) && s.activeIndex == child && s.documents.count == open)
        // Closing an edited contents document also commits it.
        _ = s.setActive(child)
        try paintChild(s, SIMD4(0, 0, 1, 1))
        try s.execute("file.close")
        #expect(SmartCommands.smartLinks(s).isEmpty)
        _ = s.setActive(0)
        #expect(F.at(try F.flat(s), 10, 20) == SIMD4(0, 0, 1, 1))
        guard case .smart? = s.active?.doc.layer(id)?.content else { Issue.record("still a smart object"); return }
    }

    @Test func rasterizeAndViaCopy() throws {
        let s = try F.session(8)
        try F.paint(s)
        try F.convert(s)
        try s.execute("filter.blur.gaussianBlur", ["radius": 2])
        let blurred = try F.flat(s)
        // Via copy: an independent smart object above.
        let copy = LayerId(try #require(try s.execute("layer.smartObjects.newSmartObjectViaCopy")["layer"]?.uint64Value))
        #expect(s.active?.activeLayer == copy)
        try s.execute("layer.smartFilter.setParams", ["params": ["radius": 8]])
        let d = try #require(s.active)
        #expect(d.doc.walk().filter { if case .smart = $0.layer.content { true } else { false } }.count == 2)
        try s.execute("edit.undo")
        try s.execute("edit.undo")
        try s.execute("layer.smartObjects.rasterize")
        guard case .raster = try F.activeLayer(s).content else { Issue.record("rasterized"); return }
        #expect(F.maxDiff(try F.flat(s), blurred) <= 1.0 / 255 + 1e-6)
        #expect(!s.isEnabled("layer.smartObjects.rasterize"))
    }

    /// A document with a smart object (embedded `bytes`, a red cached appearance, PSD placed-layer
    /// data) on top, active. Nothing here re-renders it.
    func placedSession(source: SmartSource = .embedded(fileName: "contents.pcraft", bytes: [1, 2, 3, 4])) throws -> (Session, LayerId) {
        let s = Session()
        try s.execute("file.new", ["width": 16, "height": 16])
        let id = try s.edit("place") { doc, active -> LayerId in
            var cache = Surface(format: doc.pixelFormat)
            cache.fill(PixelRect(x: 2, y: 2, width: 4, height: 4), with: PixelCodec.fromRGBA(doc.pixelFormat, SIMD4(1, 0, 0, 1)))
            var sm = SmartObject(source: source, transform: .translate(2, 2), cache: cache)
            sm.psdRaw = [9, 9]
            sm.smartFilters = [SmartFilter(command: "filter.blur.gaussianBlur", params: ["radius": 2])]
            var l = Layer(name: "Smart", content: .smart(sm))
            l.psdBlocks = [PSDLayerBlock(key: "SoLd", data: [1]), PSDLayerBlock(key: "luni", data: [2])]
            let id = doc.insertAbove(active, l)
            active = id
            return id
        }
        return (s, id)
    }

    @Test func viaCopyMakesAnIndependentSmartObjectAbove() throws {
        let (s, id) = try placedSession()
        let original = try F.smart(try #require(s.active?.doc), id)
        let copy = LayerId(try #require(try s.execute("layer.smartObjects.newSmartObjectViaCopy")["layer"]?.uint64Value))
        #expect(s.active?.activeLayer == copy)
        let layers = try #require(s.active?.doc.layers)
        #expect(layers.map(\.id).suffix(2) == [id, copy], "the copy is above the original")
        let c = try F.smart(try #require(s.active?.doc), copy)
        #expect(c.contentsId != original.contentsId, "independent contents")
        #expect(c.source == original.source && c.cache == original.cache && c.transform == original.transform && c.smartFilters == original.smartFilters)
        #expect(c.psdRaw == nil && s.active?.doc.layer(copy)?.psdBlocks.map(\.key) == ["luni"], "the PSD placed-layer data is dropped")
        #expect(throws: EngineError.self, "an explicit target must be a smart object") {
            try s.execute("layer.smartObjects.newSmartObjectViaCopy", ["layer": .id(layers[0].id)])
        }
    }

    @Test func viaCopyEmbedsALinkedFileReadThroughTheFileService() throws {
        let dir = try F.dir("viacopy")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("in.png").path
        try Data([7, 7, 7]).write(to: URL(fileURLWithPath: path))
        let (s, id) = try placedSession(source: .linked(path: path))
        let copy = LayerId(try #require(try s.execute("layer.smartObjects.newSmartObjectViaCopy")["layer"]?.uint64Value))
        let doc = try #require(s.active?.doc)
        #expect(try F.smart(doc, copy).source == .embedded(fileName: "in.png", bytes: [7, 7, 7]), "via copy embeds its own")
        #expect(try F.smart(doc, id).source == .linked(path: path))
        // A missing linked file stays linked.
        let (t, _) = try placedSession(source: .linked(path: path + ".gone"))
        let c2 = LayerId(try #require(try t.execute("layer.smartObjects.newSmartObjectViaCopy")["layer"]?.uint64Value))
        let tdoc = try #require(t.active?.doc)
        #expect(try F.smart(tdoc, c2).source == .linked(path: path + ".gone"))
        // Exporting it fails cleanly.
        #expect(throws: EngineError.other("the smart object's contents are unavailable")) {
            try t.execute("layer.smartObjects.exportContents", ["path": .string(path + ".copy")])
        }
    }

    @Test func pcraftRoundTripKeepsLiveSmartObjects() throws {
        for depth in [8, 16] {
            let s = try F.session(depth)
            try F.paint(s)
            try F.convert(s)
            try s.execute("filter.blur.gaussianBlur", ["radius": 2])
            try s.execute("select.rect", ["x": 0, "y": 0, "width": 30, "height": 30])
            try s.execute("filter.noise.addNoise", ["amount": 20, "seed": 3])
            try s.execute("layer.smartFilter.blendingOptions", ["opacity": 0.5, "blend": "screen"])
            let doc = try #require(s.active?.doc)
            let back = try PcraftFormat.load(try PcraftFormat.save(doc))
            let id = try #require(s.active?.activeLayer)
            let (a, b) = (try F.smart(doc, id), try F.smart(back, id))
            #expect(a.smartFilters == b.smartFilters && a.filterMask == b.filterMask && a.source == b.source && a.transform == b.transform,
                    "depth \(depth)")
            #expect(b.smartFilters.count == 2)
            #expect(b.filterMask != nil)
            // Still live after loading: re-editing works and matches a fresh render.
            let s2 = Session()
            s2.addDocument(back)
            try s2.selectLayer(id)
            try s2.execute("layer.smartFilter.setVisible", ["index": 1, "visible": false])
            try s.execute("layer.smartFilter.setVisible", ["index": 1, "visible": false])
            #expect(try F.flat(s2) == F.flat(s))
        }
    }

    /// A PNG embedded the way Photoshop stores placed files: a global lnk2 block keyed by uuid.
    @Test func psdPlacedLayerRendersFromLnk2Data() throws {
        var inner = F.solid("in", 10, 8, .rgb(0, 1, 0))
        let fmt8 = inner.pixelFormat
        let bg = try #require(inner.layers.first?.id)
        inner.withRaster(of: bg) { $0.fill(PixelRect(x0: 0, y0: 0, x1: 5, y1: 8), with: fmt8.components(fromRGBA: SIMD4(1, 0, 0, 1))) }
        let lnk2 = Linked.encodeLinkedFile(Linked.LinkedFile(uuid: "uuid-1", fileName: "in.png", bytes: try F.png(inner)))
        let s = try F.session(8)
        try s.edit("place") { doc, active in
            doc.metadata.psdGlobalBlocks.append(PSDGlobalBlock(signature: "8BIM", key: "lnk2", data: lnk2))
            // Photoshop's rendering (deliberately different, to see the re-render happen).
            var cache = Surface(format: doc.pixelFormat)
            cache.fill(PixelRect(x0: 20, y0: 10, x1: 40, y1: 26), with: doc.pixelFormat.components(fromRGBA: SIMD4(0, 0, 1, 1)))
            var sm = SmartObject(source: .linked(path: "uuid-1"), transform: PCAffine(a: 2, b: 0, c: 0, d: 2, e: 20, f: 10), cache: cache)
            sm.psdRaw = [1, 2, 3]
            var l = Layer(name: "placed", content: .smart(sm))
            l.psdBlocks.append(PSDLayerBlock(key: "SoLd", data: [1, 2, 3]))
            active = doc.insertAbove(active, l)
        }
        // Nothing re-renders until something changes (PSD round trips stay byte-stable).
        #expect(try #require(try F.activeSmart(s).cache).rgba(x: 25, y: 12) == SIMD4(0, 0, 1, 1))
        try s.execute("filter.other.offset", ["horizontal": 0])
        let c = try #require(try F.activeSmart(s).cache)
        #expect(c.rgba(x: 23, y: 15) == SIMD4(1, 0, 0, 1), "left half red, from the source")
        #expect(c.rgba(x: 37, y: 15) == SIMD4(0, 1, 0, 1))
        #expect(try F.activeSmart(s).psdRaw != nil, "filters alone keep the placed-layer block")
        // Embedding resolves the lnk2 data.
        #expect(s.isEnabled("layer.smartObjects.convertToEmbedded"))
        try s.execute("layer.smartObjects.convertToEmbedded")
        guard case .embedded(let name, _) = try F.activeSmart(s).source else { Issue.record("embedded"); return }
        #expect(name == "in.png")
    }

    @Test func exportReplaceAndLinkedContents() throws {
        let dir = try F.dir("export")
        let s = try F.session(8)
        try F.paint(s)
        try F.convert(s)
        let out = dir.appendingPathComponent("contents.pcraft")
        try s.execute("layer.smartObjects.exportContents", ["path": .string(out.path)])
        #expect(PcraftFormat.isPcraft([UInt8](try Data(contentsOf: out))))
        // Replace with a flat PNG.
        let pngDoc = F.solid("p", 4, 4, .rgb(1, 1, 0))
        let png = dir.appendingPathComponent("yellow.png")
        try Data(try F.png(pngDoc)).write(to: png)
        try s.execute("layer.smartObjects.replaceContents", ["path": .string(png.path)])
        #expect(try F.activeSmart(s).cache?.contentBounds == PixelRect(x0: -6, y0: 5, x1: -2, y1: 9), "transform kept")
        #expect(throws: (any Error).self) { try s.execute("layer.smartObjects.replaceContents") }
        // Linked: write out, edit the file, update.
        let linked = dir.appendingPathComponent("linked.png")
        try s.execute("layer.smartObjects.convertToLinked", ["path": .string(linked.path)])
        guard case .linked = try F.activeSmart(s).source else { Issue.record("linked"); return }
        var red = pngDoc
        let rb = red.bounds
        let fmt = red.pixelFormat
        red.withRaster(of: red.layers[0].id) { $0.fill(rb, with: fmt.components(fromRGBA: SIMD4(1, 0, 0, 1))) }
        try Data(try F.png(red)).write(to: linked)
        try s.execute("layer.smartObjects.updateAllModifiedContent")
        #expect(try F.activeSmart(s).cache?.rgba(x: -5, y: 6) == SIMD4(1, 0, 0, 1))
        try s.execute("layer.smartObjects.convertToEmbedded")
        try? FileManager.default.removeItem(at: dir)
        // Missing linked file: re-rendering fails cleanly and changes nothing.
        #expect(throws: (any Error).self) {
            try s.execute("layer.smartObjects.relinkToFile", ["path": .string(dir.appendingPathComponent("gone.png").path)])
        }
        guard case .embedded = try F.activeSmart(s).source else { Issue.record("still embedded"); return }
    }

    @Test func commandsAreRegisteredWithCatalogIds() {
        let s = Session()
        for id in [
            "layer.smartObjects.convertToSmartObject", "filter.convertForSmartFilters", "layer.smartObjects.newSmartObjectViaCopy",
            "layer.smartObjects.rasterize", "layer.smartObjects.editContents", "layer.smartObjects.replaceContents",
            "layer.smartObjects.exportContents", "layer.smartObjects.updateModifiedContent", "layer.smartObjects.updateAllModifiedContent",
            "layer.smartObjects.convertToEmbedded", "layer.smartObjects.convertToLinked", "layer.smartObjects.relinkToFile",
            "layer.smartFilter.disableSmartFilters", "layer.smartFilter.clearSmartFilters", "layer.smartFilter.blendingOptions",
            "layer.smartFilter.deleteFilterMask", "layer.smartFilter.disableFilterMask",
        ] {
            #expect(s.registry.spec(id)?.menu.isEmpty == false, "\(id)")
        }
        #expect(!s.isEnabled("layer.smartObjects.convertToSmartObject"))
        #expect(!s.isEnabled("layer.smartObjects.editContents"))
    }

    /// Every smart_cmds command is registered, available, with photocraft's id, label, menu path,
    /// shortcut and params, and nothing else is registered under the module.
    @Test func registrationsMatchPhotocraftsCatalogue() throws {
        let r = CommandRegistry.standard()
        let expected = PhotocraftCatalog.commands.filter { $0.module == "smart_cmds" }
        #expect(expected.count == 24)
        for c in expected {
            let spec = try #require(r.spec(c.id), "\(c.id)")
            #expect(spec.module == c.module && spec.label == c.label && spec.menu == c.menu, "\(c.id)")
            #expect(spec.shortcut == c.shortcut && spec.params == c.params, "\(c.id)")
            #expect(spec.isAvailable, "\(c.id)")
        }
        for spec in r.specs where spec.module == "smart_cmds" {
            #expect(PhotocraftCatalog.byId[spec.id]?.module == "smart_cmds", "\(spec.id) is not a photocraft smart_cmds command")
        }
    }

    @Test func smartFilterBlurRepeatsTheCanvasEdgeLikeALayerFilter() throws {
        for depth in [8, 32] {
            func fillCanvas(_ s: Session) throws {
                try s.edit("setup") { doc, active in
                    let id = try #require(active)
                    doc.withRaster(of: id) { surf in
                        let fmt = surf.format
                        let r = PixelRect(x0: 0, y0: 0, x1: F.W, y1: F.H)
                        var data: [Float] = []
                        for y in r.y0..<r.y1 {
                            for x in r.x0..<r.x1 {
                                let v: Float = (x / 8 + y / 8) % 2 == 0 ? 0.2 : 0.9
                                data += fmt.components(fromRGBA: SIMD4(v, 0.5, 1 - v, 1))
                            }
                        }
                        surf.writeRegion(r, data)
                    }
                }
            }
            let layer = try F.session(depth)
            try fillCanvas(layer)
            try layer.execute("filter.blur.gaussianBlur", ["radius": 4])
            let smart = try F.session(depth)
            try fillCanvas(smart)
            try F.convert(smart)
            try smart.execute("filter.blur.gaussianBlur", ["radius": 4])
            let (a, b) = (try F.flat(layer), try F.flat(smart))
            // The corner stays opaque (no transparency fades in from outside the canvas).
            #expect(abs(b[0].w - 1) < 1e-3, "corner alpha \(b[0].w)")
            #expect(F.maxDiff(a, b) < 2.0 / 255, "smart re-render matches the layer filter (\(depth)-bit)")
        }
    }

    /// A distorted smart object keeps its fourth corner: through Edit Contents → Save (which
    /// re-renders from the source) the placement and the rendered corners don't move.
    @Test func distortSurvivesEditContents() throws {
        let s = try F.session(8)
        try F.paint(s)
        let id = try F.convert(s)
        let r = try #require(try F.activeSmart(s).cache).contentBounds
        let (x0, y0, x1, y1) = (Int(r.x0), Int(r.y0), Int(r.x1), Int(r.y1))
        // Distort: only the bottom-right corner moves (in by 12, up by 8): not a parallelogram.
        let quad: JSONValue = [[.int(x0), .int(y0)], [.int(x1), .int(y0)], [.int(x1 - 12), .int(y1 - 8)], [.int(x0), .int(y1)]]
        try s.execute("edit.transform", ["layer": .id(id), "rect": [.int(x0), .int(y0), .int(x1), .int(y1)], "quad": quad])
        let placed = try F.activeSmart(s)
        #expect(placed.perspective != nil, "Distort keeps a projective placement")
        let before = try F.flat(s)
        try s.execute("layer.smartObjects.editContents")
        try s.execute("layer.smartObjects.saveContents")
        _ = s.setActive(0)
        #expect(try F.activeSmart(s).perspective == placed.perspective, "the placement survives the save")
        #expect(F.meanDiff(before, try F.flat(s)) < 0.01, "the re-render matches the distorted look")
        // The bottom-right of the original frame is now empty: the corner really moved in.
        let c = try #require(try F.activeSmart(s).cache)
        #expect(c.rgba(x: Int32(x1 - 2), y: Int32(y1 - 2)).w == 0, "no pixels where the corner used to be")
    }

    /// Warp handles on a distorted smart object sit on its four distorted corners (the warp is
    /// mapped through the full projective placement, not its affine approximation), and warping
    /// it keeps the Distort placement.
    @Test func warpOnADistortedSmartObjectFollowsTheCorners() throws {
        let s = try F.session(8)
        try F.paint(s)
        let id = try F.convert(s)
        let r = try #require(try F.activeSmart(s).cache).contentBounds
        let (x0, y0, x1, y1) = (Double(r.x0), Double(r.y0), Double(r.x1), Double(r.y1))
        let quad: [SIMD2<Double>] = [SIMD2(x0, y0), SIMD2(x1, y0), SIMD2(x1 - 12, y1 - 8), SIMD2(x0, y1)]
        try s.execute("edit.transform", ["layer": .id(id), "rect": .doubles([x0, y0, x1, y1]), "quad": .array(quad.map { .doubles([$0.x, $0.y]) })])
        var sm = try F.activeSmart(s)
        let inv = try #require(TransformCommands.placement(sm).inverse())
        let src = quad.map { inv.apply($0.x, $0.y) }
        let b = SIMD4(src.map(\.0).min() ?? 0, src.map(\.1).min() ?? 0, src.map(\.0).max() ?? 0, src.map(\.1).max() ?? 0)
        sm.warp = Warp.custom(BezierMesh.identity(bounds: b, cols: 1, rows: 1), bounds: b)
        let layer = Layer(name: "w", content: .smart(sm))
        let docWarp = try #require(WarpCommands.smartWarpDocSpace(layer))
        let pts = try #require(docWarp.mesh).points
        for (q, i) in zip(quad, [0, 3, 15, 12]) {
            #expect(abs(pts[i].x - q.x) < 1e-6 && abs(pts[i].y - q.y) < 1e-6, "corner \(i): \(pts[i]) vs \(q)")
        }
        // Warping the distorted smart object works and keeps its projective placement.
        let before = try F.activeSmart(s).perspective
        #expect(before != nil)
        try s.execute("edit.transform.warp", ["style": "arc", "bend": 30])
        let after = try F.activeSmart(s)
        #expect(after.warp != nil)
        #expect(after.perspective == before)
    }

    // MARK: Convert to Layers

    @discardableResult
    func convertToLayers(_ s: Session) throws -> JSONValue { try s.execute("layer.smartObjects.convertToLayers") }

    @Test func convertToLayersRoundTripsALayerAtEveryDepth() throws {
        for depth in F.depths {
            let s = try F.session(depth)
            try F.paint(s)
            let id = try #require(s.active?.activeLayer)
            try s.edit("props") { doc, _ in
                doc.updateLayer(id) { l in
                    l.name = "Sky"
                    l.opacity = 0.6
                    l.blend = .multiply
                }
            }
            let before = try F.flat(s)
            try F.convert(s)
            let smart = try F.flat(s)
            let r = try convertToLayers(s)
            #expect(r["group"] == false, "one layer replaces the smart object")
            let l = try F.activeLayer(s)
            #expect(l.id.rawValue == r["layer"]?.uint64Value)
            guard case .raster(let px) = l.content else { Issue.record("depth \(depth): not raster"); continue }
            #expect(px.format == s.active?.doc.pixelFormat, "depth \(depth)")
            #expect(l.name == "Sky" && l.blend == .multiply)
            #expect(abs(l.opacity - 0.6) < 1e-6)
            #expect(F.maxDiff(try F.flat(s), before) == 0, "depth \(depth): whole-pixel placement is exact")
            _ = s.undo()
            guard case .smart = try F.activeLayer(s).content else { Issue.record("one undoable step"); continue }
            #expect(try F.flat(s) == smart)
        }
    }

    @Test func convertToLayersUnpacksSeveralLayersIntoAGroupWithTheSmartLayersProperties() throws {
        let s = try F.session(8)
        try F.paint(s)
        let id = try F.convert(s)
        try s.execute("layer.setProps", ["layer": .id(id), "name": "Placed", "opacity": 0.5])
        // A second layer inside the contents (Edit Contents, then save).
        let child = Int(try #require(try s.execute("layer.smartObjects.editContents")["document"]?.uint64Value))
        try s.execute("layer.new.layer", ["name": "Top"])
        try s.edit("paint") { doc, active in
            let fmt = doc.pixelFormat
            let id = try #require(active)
            doc.withRaster(of: id) { $0.fill(PixelRect(x0: 2, y0: 2, x1: 8, y1: 8), with: fmt.components(fromRGBA: SIMD4(0, 0, 1, 1))) }
        }
        try s.execute("layer.smartObjects.saveContents")
        try s.execute("file.close")
        #expect(s.activeIndex != child)
        try s.execute("filter.blur.gaussianBlur", ["radius": 2])
        try s.execute("filter.blur.gaussianBlur", ["radius": 1])
        // Without the filters, the smart object looks exactly like the unpacked group.
        try s.execute("layer.smartFilter.disableSmartFilters")
        let before = try F.flat(s)
        let r = try convertToLayers(s)
        #expect(r["group"]?.boolValue == true && r["discardedSmartFilters"]?.uint64Value == 2)
        let g = try F.activeLayer(s)
        #expect(g.name == "Placed" && g.blend == .normal, "named after the smart object, isolated")
        #expect(abs(g.opacity - 0.5) < 1e-6)
        let names = (g.children ?? []).map(\.name)
        #expect(names.last == "Top")
        #expect(names.count == 2)
        #expect(F.maxDiff(try F.flat(s), before) <= 1.0 / 255 + 1e-6)
        #expect(!s.isEnabled("layer.smartObjects.convertToLayers"), "a group isn't a smart object")
    }

    @Test func convertToLayersKeepsASmartLayerMaskOnAGroup() throws {
        let s = try F.session(16)
        try F.paint(s)
        try F.convert(s)
        try s.execute("layer.layerMask.hideAll")
        let before = try F.flat(s)
        #expect(try convertToLayers(s)["group"]?.boolValue == true, "the mask can't fold into the layer")
        let g = try F.activeLayer(s)
        #expect(g.mask != nil && g.children?.first?.mask == nil)
        #expect(F.maxDiff(try F.flat(s), before) == 0)
    }

    @Test func convertToLayersAppliesThePlacement() throws {
        var s = try F.session(8)
        try F.paint(s)
        var id = try F.convert(s)
        try s.execute("edit.transform", ["layer": .id(id), "matrix": [0.5, 0, 0, 0.5, 10.25, 3]])
        var before = try F.flat(s)
        try convertToLayers(s)
        guard case .raster = try F.activeLayer(s).content else { Issue.record("raster"); return }
        let err = F.meanDiff(try F.flat(s), before)
        #expect(err < 2e-3, "\(err)")
        // Distort keeps the projective placement for pixels.
        s = try F.session(8)
        try F.paint(s)
        id = try F.convert(s)
        try s.execute("edit.transform", ["layer": .id(id), "quad": [[0, 0], [30, 0], [36, 30], [-4, 30]]])
        before = try F.flat(s)
        try convertToLayers(s)
        #expect(F.meanDiff(try F.flat(s), before) < 2e-3)
    }

    @Test func convertToLayersRejectsWhatItCannotUnpack() throws {
        let s = try F.session(8)
        #expect(!s.isEnabled("layer.smartObjects.convertToLayers"))
        #expect(throws: (any Error).self) { try s.execute("layer.smartObjects.convertToLayers") }
        try F.paint(s)
        let raster = try #require(s.active?.activeLayer)
        let id = try F.convert(s)
        // Bad targets fail without trapping: a pixel layer, a missing layer. (photocraft passes
        // u64::MAX; JSON numbers are doubles here, so the largest exact integer stands in.)
        for p: JSONValue in [["layer": .id(raster)], ["layer": .number(9_007_199_254_740_991)]] {
            #expect(throws: (any Error).self) { try s.execute("layer.smartObjects.convertToLayers", p) }
        }
        // A warp can't be applied to the unpacked layers: an error, and the document is unchanged.
        try s.execute("edit.transform.warp", ["layer": .id(id), "style": "arc", "bend": 30])
        let steps = s.active?.history.pastCount
        #expect(throws: (any Error).self) { try s.execute("layer.smartObjects.convertToLayers") }
        #expect(s.active?.history.pastCount == steps)
    }

    /// Two instances of the same contents unpacked in one document get distinct layer ids.
    @Test func convertToLayersNeverDuplicatesLayerIds() throws {
        let s = try F.session(8)
        try F.paint(s)
        let a = try F.convert(s)
        try s.execute("layer.duplicate")
        let b = try #require(s.active?.activeLayer)
        let first = try s.execute("layer.smartObjects.convertToLayers", ["layer": .id(a)])
        let second = try s.execute("layer.smartObjects.convertToLayers", ["layer": .id(b)])
        #expect(first["layer"] != second["layer"])
        let ids = try #require(s.active?.doc.allLayerIds)
        #expect(Set(ids).count == ids.count)
    }

    @Test func convertToLayersConformsTheContentsToTheDocumentModeAndDepth() throws {
        let s = try F.session(8)
        try F.paint(s)
        try F.convert(s)
        // The contents stay 8-bit RGB while the document becomes 16-bit grayscale.
        try s.execute("image.mode.bits16")
        try s.execute("image.mode.grayscale")
        try convertToLayers(s)
        let fmt = try #require(s.active?.doc.pixelFormat)
        guard case .raster(let px) = try F.activeLayer(s).content else { Issue.record("raster"); return }
        #expect(px.format.mode == fmt.mode && px.format.sample == fmt.sample)
    }

    // MARK: Automation (sources are re-checked by the session's gate)

    static let denyContentsPaths: @Sendable (String, JSONValue) throws -> Void = { cmd, p in
        if ["layer.smartObjects.editContents", "layer.smartObjects.convertToLayers", "layer.smartObjects.saveContents"].contains(cmd),
           let path = p["path"] {
            throw EngineError.other("source path refused: \(cmd): \(path)")
        }
    }

    @Test func automationSmartContentsAcceptsMemorySourcesAndExplicitTargets() throws {
        for (depth, psdUUID) in [(8, false), (16, true), (32, false)] {
            let s = try F.session(depth)
            try F.paint(s)
            let id = try F.convert(s)
            if psdUUID {
                try s.edit("PSD source") { doc, _ in
                    guard case .embedded(let fileName, let bytes) = try F.smart(doc, id).source else { throw EngineError.other("not embedded") }
                    let linked = Linked.LinkedFile(uuid: "embedded-id", fileName: fileName, bytes: bytes)
                    doc.metadata.psdGlobalBlocks.append(PSDGlobalBlock(signature: "8BIM", key: "lnk2", data: Linked.encodeLinkedFile(linked)))
                    try SmartCommands.updateSmart(&doc, id) { $0.source = .linked(path: linked.uuid) }
                }
            }
            // An explicit smart-object target must work while a pixel layer is selected.
            let raster = LayerId(try #require(try s.execute("layer.new.layer")["layer"]?.uint64Value))
            s.authorize = Self.denyContentsPaths
            let child = Int(try #require(try s.execute("layer.smartObjects.editContents", ["layer": .id(id)])["document"]?.uint64Value))
            #expect(s.active?.doc.depth.bytes == depth / 8)
            #expect(s.active?.path == nil)
            #expect(s.documents[0].activeLayer == raster)
            _ = s.close(child)
            let r = try s.execute("layer.smartObjects.convertToLayers", ["layer": .id(id)])
            let lid = LayerId(try #require(r["layer"]?.uint64Value))
            let l = try #require(s.active?.doc.layer(lid))
            guard case .raster = l.content else { Issue.record("depth \(depth): raster"); continue }
        }
    }

    /// A 4×4 red `.pcraft` contents file.
    func contentsFile() throws -> URL {
        let doc = F.solid("source", 4, 4, .rgb(1, 0, 0))
        let url = try F.dir("contents").appendingPathComponent("contents-\(doc.id.rawValue).pcraft")
        try Data(try SmartCommands.encodeSource(doc)).write(to: url)
        return url
    }

    @Test func automationSmartContentsRefusesDiskSourcesBeforeChanges() throws {
        let path = try contentsFile()
        let sourceBytes = try Data(contentsOf: path)
        for cmd in ["layer.smartObjects.editContents", "layer.smartObjects.convertToLayers"] {
            let s = try F.session(8)
            try F.paint(s)
            let id = try F.convert(s)
            let sibling = try s.edit("linked sources") { doc, _ -> LayerId in
                let source = SmartSource.linked(path: path.path)
                try SmartCommands.updateSmart(&doc, id) { $0.source = source }
                var cache = Surface(format: doc.pixelFormat)
                cache.fill(PixelRect(x0: 0, y0: 0, x1: 4, y1: 4), with: doc.pixelFormat.components(fromRGBA: SIMD4(0, 0, 1, 1)))
                let sib = Layer(name: "linked sibling", content: .smart(SmartObject(source: source, transform: .identity, cache: cache)))
                var layers = doc.layers
                layers.insert(sib, at: 0)
                doc.layers = layers
                return sib.id
            }
            s.authorize = Self.denyContentsPaths
            let before = s.active?.doc
            let revision = s.active?.revision
            let history = s.active?.history.pastCount
            do {
                try s.execute(cmd, ["layer": .id(id)])
                Issue.record("\(cmd): the disk source is refused")
            } catch {
                let text = "\(error)"
                #expect(text.contains("source path refused") && text.contains(path.lastPathComponent), "\(text)")
            }
            #expect(s.active?.doc == before)
            #expect(s.documents.count == 1 && s.active?.revision == revision && s.active?.history.pastCount == history)

            // Human commands retain their linked-file behavior. Returning to an already-open child
            // reads no source, and saving it updates only its parent layer, never a linked sibling.
            s.authorize = nil
            let r = try s.execute(cmd, ["layer": .id(id)])
            if cmd.hasSuffix("editContents") {
                let child = Int(try #require(r["document"]?.uint64Value))
                _ = s.setActive(0)
                s.authorize = Self.denyContentsPaths
                let again = try s.execute(cmd, ["layer": .id(id)])
                #expect(again["document"] == r["document"])
                #expect(s.documents.count == 2)
                try s.execute("image.adjustments.invert")
                try s.execute("layer.smartObjects.saveContents")
                #expect(s.active?.isDirty == false)
                let parent = s.documents[0].doc
                guard case .embedded = try F.smart(parent, id).source else { Issue.record("embedded after the save"); continue }
                #expect(try F.smart(parent, sibling).cache?.rgba(x: 1, y: 1) == SIMD4(0, 0, 1, 1))
                _ = s.close(child)
            } else {
                let lid = LayerId(try #require(r["layer"]?.uint64Value))
                let l = try #require(s.active?.doc.layer(lid))
                #expect(l.surface?.rgba(x: -5, y: 6) == SIMD4(1, 0, 0, 1))
            }
        }
        #expect(try Data(contentsOf: path) == sourceBytes, "committing contents does not overwrite the linked file")
        try? FileManager.default.removeItem(at: path.deletingLastPathComponent())
    }

    @Test func automationSmartContentsChecksNestedReadsAtNontrivialPlacements() throws {
        let path = try contentsFile()
        for (scale, psdUUID, allowed) in [(1.0, false, true), (1.5, false, false), (1.5, true, true)] {
            var inner = Document(name: "inner", size: PixelSize(width: 4, height: 4), mode: .rgb, depth: .u8)
            let sourcePath: String
            if psdUUID {
                let linked = Linked.LinkedFile(uuid: "nested-id", fileName: "source.pcraft", bytes: [UInt8](try Data(contentsOf: path)))
                inner.metadata.psdGlobalBlocks.append(PSDGlobalBlock(signature: "8BIM", key: "lnk2", data: Linked.encodeLinkedFile(linked)))
                sourcePath = linked.uuid
            } else {
                sourcePath = path.path
            }
            var cache = Surface(format: inner.pixelFormat)
            cache.fill(PixelRect(x0: 0, y0: 0, x1: 4, y1: 4), with: inner.pixelFormat.components(fromRGBA: SIMD4(0, 0, 1, 1)))
            let nested = Layer(name: "nested", content: .smart(SmartObject(source: .linked(path: sourcePath), transform: .identity, cache: cache)))
            inner.layers = [Layer.group("group", [nested])]
            var parent = Document(name: "parent", size: PixelSize(width: 8, height: 8), mode: inner.mode, depth: inner.depth)
            parent.layers = [Layer(name: "outer", content: .smart(SmartObject(
                source: .embedded(fileName: "inner.pcraft", bytes: try SmartCommands.encodeSource(inner)),
                transform: PCAffine(a: scale, b: 0, c: 0, d: scale, e: 0, f: 0), cache: cache)))]
            let s = Session()
            s.addDocument(parent)
            s.authorize = Self.denyContentsPaths
            let before = s.active?.doc
            do {
                try s.execute("layer.smartObjects.convertToLayers")
                #expect(allowed, "scale \(scale): the nested disk read is refused")
                let sm = try #require(s.active?.doc.walk().compactMap { e -> SmartObject? in
                    if case .smart(let sm) = e.layer.content { return sm }
                    return nil
                }.first)
                #expect(sm.cache?.rgba(x: 1, y: 1) == (psdUUID ? SIMD4(1, 0, 0, 1) : SIMD4(0, 0, 1, 1)), "scale \(scale) uuid \(psdUUID)")
            } catch {
                #expect(!allowed, "scale \(scale): \(error)")
                #expect("\(error)".contains("source path refused"))
                #expect(s.active?.doc == before)
                #expect(s.active?.revision == 1)
            }
        }
        try? FileManager.default.removeItem(at: path.deletingLastPathComponent())
    }

    @Test func automationSmartContentsMalformedEmbeddedSourcesLeaveDocumentsUnchanged() throws {
        for cmd in ["layer.smartObjects.editContents", "layer.smartObjects.convertToLayers"] {
            let s = try F.session(8)
            try F.paint(s)
            let id = try F.convert(s)
            try s.edit("bad source") { doc, _ in
                try SmartCommands.updateSmart(&doc, id) { $0.source = .embedded(fileName: "broken.psd", bytes: Array("8BPS".utf8)) }
            }
            s.authorize = Self.denyContentsPaths
            let before = s.active?.doc
            let revision = s.active?.revision
            #expect(throws: (any Error).self) { try s.execute(cmd) }
            #expect(s.active?.doc == before)
            #expect(s.documents.count == 1 && s.active?.revision == revision)
        }
    }

    @Test func inspectReportsTheSmartSource() throws {
        // A PSD placed layer: its file in the global `lnk2` block, the layer linked to its uuid.
        let inner = F.solid("in", 4, 4, .rgb(0, 1, 0))
        let lnk2 = Linked.encodeLinkedFile(Linked.LinkedFile(uuid: "uuid-1", fileName: "in.png", bytes: try F.png(inner)))
        var s = try F.session(8)
        try s.edit("place") { doc, active in
            doc.metadata.psdGlobalBlocks.append(PSDGlobalBlock(signature: "8BIM", key: "lnk2", data: lnk2))
            let sm = SmartObject(source: .linked(path: "uuid-1"), transform: .identity, cache: nil)
            active = doc.insertAbove(active, Layer(name: "front", content: .smart(sm)))
        }
        func source(_ s: Session) throws -> JSONValue? { Inspect.layer(try F.activeLayer(s))["smartSource"] }
        let front = try source(s)
        #expect(front == ["kind": "linked", "path": "uuid-1"])
        // A duplicate shares the file; New Smart Object via Copy gets its own.
        try s.execute("layer.duplicate")
        #expect(try source(s) == front, "a duplicate shares its source")
        try s.execute("layer.smartObjects.newSmartObjectViaCopy")
        #expect(try source(s) == ["kind": "embedded", "fileName": "in.png"], "via copy embeds its own")

        s = try F.session(8)
        try F.paint(s)
        try F.convert(s)
        #expect(try source(s)?["kind"] == "embedded")
        #expect(try source(s)?["fileName"]?.stringValue != nil)
    }

    @Test func displaceSmartFilterReadsItsMapPathOnReRender() throws {
        let dir = try F.dir("displace")
        defer { try? FileManager.default.removeItem(at: dir) }
        // A white map displaces by the full scale; mid-grey would not move anything.
        let map = dir.appendingPathComponent("white.png")
        try Data(try F.png(F.solid("map", Int(F.W), Int(F.H), .rgb(1, 1, 1)))).write(to: map)
        for depth in F.depths {
            let s = try F.session(depth)
            try F.paint(s)
            try F.convert(s)
            let before = try F.flat(s)
            try s.execute("filter.distort.displace", ["horizontal": 8, "vertical": 8, "mapPath": .string(map.path)])
            #expect(F.maxDiff(before, try F.flat(s)) > 0.1, "the smart filter displaced the pixels at \(depth)-bit")
            // A later re-render (here: hide and show the filter) reads the map again.
            try s.execute("layer.smartFilter.setVisible", ["index": 0, "visible": false])
            #expect(F.maxDiff(before, try F.flat(s)) == 0, "hidden at \(depth)-bit")
            try s.execute("layer.smartFilter.setVisible", ["index": 0, "visible": true])
            #expect(F.maxDiff(before, try F.flat(s)) > 0.1, "shown again at \(depth)-bit")
        }
    }

    /// The compositor's fallback for a smart object without a cache (`PlatformRasterizer`) renders
    /// its embedded source through the refresh path, at any placement and with its smart filters;
    /// a linked file on disk isn't read there (it stays a reported miss).
    @Test func compositorRendersACachelessSmartObjectFromItsSource() throws {
        let s = try F.session(8)
        let png = try F.png(F.solid("p", 4, 4, .rgb(1, 1, 0)))
        let id = try s.edit("place") { doc, active -> LayerId in
            var sm = SmartObject(source: .embedded(fileName: "p.png", bytes: png), transform: PCAffine(a: 2.5, b: 0, c: 0, d: 2.5, e: 10, f: 10), cache: nil)
            sm.smartFilters = [SmartFilter(command: "image.adjustments.invert")]
            let l = Layer(name: "cacheless", content: .smart(sm))
            active = doc.insertAbove(active, l)
            return l.id
        }
        let doc = try #require(s.active?.doc)
        // A private rasterizer: its miss log isn't the shared renderer's.
        let rasterizer = PlatformRasterizer()
        let layer = try #require(doc.layer(id))
        let px = try #require(rasterizer.rasterize(layer, in: doc))
        let b = px.contentBounds
        #expect(b.x0 >= 8 && b.y0 >= 8 && b.x1 <= 22 && b.y1 <= 22 && b.x0 <= 10 && b.x1 >= 20, "4 px scaled 2.5× at 10: \(b)")
        #expect(px.rgba(x: 15, y: 15) == SIMD4(0, 0, 1, 1), "yellow, scaled 2.5×, inverted by its smart filter")
        // The canvas composite draws it too.
        let c = F.flat
        #expect(F.at(try c(s), 15, 15) == SIMD4(0, 0, 1, 1))
        // A linked file isn't read by the compositor.
        let dir = try F.dir("cacheless")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("p.png")
        try Data(png).write(to: file)
        let linked = Layer(name: "linked", content: .smart(SmartObject(source: .linked(path: file.path), transform: .identity, cache: nil)))
        #expect(rasterizer.rasterize(linked, in: doc) == nil)
        #expect(rasterizer.misses.contains("smart object linked"))
    }

    // MARK: Linked files changed on disk (photocraft link_watch.rs tests)

    /// A 40×40 white document with the PNG at `path` placed linked at the origin → (session, id).
    func placed(_ path: URL) throws -> (Session, LayerId) {
        let s = Session()
        try s.execute("file.new", ["width": 40, "height": 40])
        let bytes = [UInt8](try Data(contentsOf: path))
        let id = try s.edit("place") { doc, active -> LayerId in
            let sm = SmartObject(source: .linked(path: path.path), transform: .translate(15, 15), cache: nil)
            let l = Layer(name: "art", content: .smart(sm))
            active = doc.insertAbove(active, l)
            try SmartCommands.refreshOrFail(&doc, l.id, services: EngineServices())
            return l.id
        }
        #expect(!bytes.isEmpty)
        return (s, id)
    }

    func centre(_ s: Session) throws -> SIMD3<Float> {
        let doc = try #require(s.active?.doc)
        let p = try #require(try s.services.renderer.renderCPU(doc, region: PixelRect(x0: 20, y0: 20, x1: 21, y1: 21)).px.first)
        return SIMD3(p.x, p.y, p.z)
    }

    func isColor(_ c: SIMD3<Float>, _ rgb: SIMD3<Float>) -> Bool { (0..<3).allSatisfy { Swift.abs(c[$0] - rgb[$0]) < 0.02 } }

    @Test func aLinkedSmartObjectFollowsItsFile() throws {
        let d = try F.dir("follow")
        defer { try? FileManager.default.removeItem(at: d) }
        let path = d.appendingPathComponent("art.png")
        try Data(try F.png(F.solid("r", 10, 10, .rgb(1, 0, 0)))).write(to: path)
        let (s, id) = try placed(path)
        #expect(isColor(try centre(s), SIMD3(1, 0, 0)))
        // First look: remembered, nothing to update.
        #expect(try s.execute("layer.smartObjects.updateChanged") == ["updated": []])
        try Data(try F.png(F.solid("b", 10, 10, .rgb(0, 0, 1)))).write(to: path)
        #expect(try s.execute("layer.smartObjects.updateChanged") == ["updated": .ids([id])])
        #expect(isColor(try centre(s), SIMD3(0, 0, 1)))
        // An Update Modified Content step: undoing it is respected until the file changes again.
        #expect(s.undo())
        #expect(isColor(try centre(s), SIMD3(1, 0, 0)))
        #expect(try s.execute("layer.smartObjects.updateChanged") == ["updated": []])
        #expect(isColor(try centre(s), SIMD3(1, 0, 0)))
    }

    @Test func aFileStillBeingWrittenIsTriedAgain() throws {
        let d = try F.dir("partial")
        defer { try? FileManager.default.removeItem(at: d) }
        let path = d.appendingPathComponent("art.png")
        try Data(try F.png(F.solid("r", 10, 10, .rgb(1, 0, 0)))).write(to: path)
        let (s, id) = try placed(path)
        try s.execute("layer.smartObjects.updateChanged")
        let undo = s.active?.history.pastCount
        // Another app has only written the start of the file so far.
        let full = try F.png(F.solid("b", 10, 10, .rgb(0, 0, 1)))
        try Data(full.prefix(16)).write(to: path)
        #expect(try s.execute("layer.smartObjects.updateChanged") == ["updated": []])
        #expect(isColor(try centre(s), SIMD3(1, 0, 0)), "the last good pixels stay")
        #expect(s.active?.history.pastCount == undo, "no step for a failed update")
        try Data(full).write(to: path)
        #expect(try s.execute("layer.smartObjects.updateChanged") == ["updated": .ids([id])])
        #expect(isColor(try centre(s), SIMD3(0, 0, 1)))
    }

    @Test func aDocumentInTheBackCatchesUpInFront() throws {
        let d = try F.dir("back")
        defer { try? FileManager.default.removeItem(at: d) }
        let path = d.appendingPathComponent("art.png")
        try Data(try F.png(F.solid("r", 10, 10, .rgb(1, 0, 0)))).write(to: path)
        let (s, id) = try placed(path)
        try s.execute("layer.smartObjects.updateChanged")
        try s.execute("file.new", ["width": 10, "height": 10])
        try Data(try F.png(F.solid("b", 10, 10, .rgb(0, 0, 1)))).write(to: path)
        #expect(try s.execute("layer.smartObjects.updateChanged") == ["updated": []])
        _ = s.setActive(0)
        #expect(try s.execute("layer.smartObjects.updateChanged") == ["updated": .ids([id])])
        #expect(isColor(try centre(s), SIMD3(0, 0, 1)))
    }
}
