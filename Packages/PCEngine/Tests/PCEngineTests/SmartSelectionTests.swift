// Port of photocraft-engine (crates/engine/src/smart_cmds/tests/selection.rs, tests/stack_cache.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Convert to Smart Object with several layers selected (every mode and depth, groups, mixed
// parents, PSD and .pcraft round trips), and the smart filter stage cache.

import Foundation
@testable import PCEngine
import PCDocument
import PCFormat
import PCFoundation
import PCPlatform
import Testing

@Suite struct SmartSelectionTests {
    typealias F = SmartFixture

    func pixel(_ doc: Document, _ name: String, _ bounds: PixelRect, _ rgba: SIMD4<Float>) -> Layer {
        var layer = Layer.raster(name, format: doc.pixelFormat)
        layer.withRaster { $0.fill(bounds, with: doc.pixelFormat.components(fromRGBA: rgba)) }
        return layer
    }

    func selectedSession(_ doc: Document, _ ids: [LayerId]) throws -> Session {
        let s = Session()
        s.addDocument(doc)
        try LayerMulti.setSelection(s, ids, active: ids.last, anchor: nil)
        return s
    }

    func contents(_ s: Session) throws -> Document {
        guard case .embedded(let fileName, let bytes) = try F.activeSmart(s).source else { throw EngineError.other("not embedded") }
        return try SmartCommands.decodeSource(fileName, bytes, services: s.services)
    }

    func rect(_ x0: Int32, _ y0: Int32, _ x1: Int32, _ y1: Int32) -> PixelRect { PixelRect(x0: x0, y0: y0, x1: x1, y1: y1) }

    @Test func selectedPixelsBecomeOneEditableSmartObjectInEveryModeAndDepth() throws {
        for mode in [ColorMode.rgb, .grayscale, .cmyk, .lab] {
            for depth in SampleType.allCases {
                var doc = Document(name: "Selected", size: PixelSize(width: Int(F.W), height: Int(F.H)), mode: mode, depth: depth)
                let profile: BuiltinProfile = switch mode {
                case .rgb: .srgb
                case .grayscale: .sGray
                case .cmyk: .coatedCMYK
                default: .labD50
                }
                doc.iccProfile = [UInt8](profile.profile.data)
                doc.resolutionDpi = 300
                let a = pixel(doc, "Bottom", rect(-3, 4, 24, 26), SIMD4(0.8, 0.2, 0.1, 1))
                var b = pixel(doc, "Top", rect(10, 12, 36, 32), SIMD4(0.1, 0.4, 0.8, 0.7))
                var m = LayerMask.revealAll()
                m.surface.fill(rect(14, 16, 20, 22), with: [0.5])
                b.mask = m
                b.locks.all = true
                b.effects.enabled = true
                b.effects.items.append(.colorOverlay(Effect.ColorOverlay(common: FxCommon(enabled: true, blend: .normal, opacity: 0.3), color: .rgb(1, 1, 1))))
                var hidden = pixel(doc, "Hidden", rect(50, 40, 58, 44), SIMD4(0.2, 0.9, 0.3, 1))
                hidden.visible = false
                let ids = [a.id, b.id, hidden.id]
                doc.layers = [a, b, hidden]
                var selection = Surface(format: .gray8)
                selection.fill(rect(0, 0, 12, 12), with: [0.5])
                doc.selection = selection
                let original = doc
                // Selection order must not change stacking order.
                let s = try selectedSession(doc, [ids[2], ids[1], ids[0]])
                let before = try F.flat(s)
                let grouped = try selectedSession(original, ids)
                try grouped.execute("layer.groupLayers")
                try F.convert(grouped)
                let id = try F.convert(s)
                let tag = "\(mode) \(depth)"
                #expect(s.active?.doc.layers.count == 1, "\(tag)")
                #expect(s.active?.selectedLayers == [id])
                #expect(s.active?.doc.selection == original.selection)
                // The cache conversion quantizes channels and round-trips CMYK through RGB.
                // Combining a selection must introduce no loss beyond grouping then converting.
                #expect(try F.flat(s) == F.flat(grouped), "selection conversion matches Group Layers then Convert: \(tag)")
                if mode == .rgb || mode == .grayscale {
                    #expect(F.maxDiff(try F.flat(s), before) <= 2.0 / 255, "\(tag)")
                }
                let inner = try contents(s)
                #expect(inner.mode == mode && inner.depth == depth)
                #expect(inner.iccProfile == original.iccProfile)
                #expect(inner.resolutionDpi == original.resolutionDpi)
                // Like Photoshop, the contents hold the selected layers at their top level, in
                // stacking order, with no wrapper group.
                #expect(inner.layers.map(\.id) == ids, "\(tag)")
                let sm = try F.activeSmart(s)
                for source in original.layers {
                    var shifted = source
                    SmartCommands.shiftLayer(&shifted, -Int32(sm.transform.e), -Int32(sm.transform.f))
                    #expect(inner.layer(source.id) == shifted, "editable source preserved: \(tag) \(source.name)")
                }
                #expect(s.undo())
                #expect(s.active?.doc == original)
                #expect(s.active?.selectedLayers == ids)
                #expect(!s.undo(), "conversion is one undo step")
                #expect(s.redo())
                #expect(s.active?.selectedLayers == [id])
                #expect(try contents(s) == inner)
            }
        }
    }

    @Test func selectedGroupAndDescendantAreEmbeddedOnce() throws {
        var doc = Document(name: "Groups", size: PixelSize(width: Int(F.W), height: Int(F.H)), mode: .rgb, depth: .u16)
        let a = pixel(doc, "Child", rect(0, 0, 16, 16), SIMD4(1, 0, 0, 1))
        let group = Layer.group("Original group", [a])
        let b = pixel(doc, "Outside", rect(16, 0, 32, 16), SIMD4(0, 0, 1, 1))
        doc.layers = [group, b]
        let s = try selectedSession(doc, [group.id, a.id, b.id])
        try F.convert(s)
        #expect(s.active?.doc.layers.count == 1)
        let inner = try contents(s)
        #expect(inner.walk().filter { $0.layer.id == a.id }.count == 1)
        #expect(inner.layers.map(\.id) == [group.id, b.id], "a selected group stays a group")
        #expect(inner.layer(group.id)?.children?.first?.id == a.id)
    }

    @Test func mixedParentSelectionKeepsUnselectedSiblingsAndUsesTheTopSelectedParent() throws {
        var doc = Document(name: "Parents", size: PixelSize(width: Int(F.W), height: Int(F.H)), mode: .rgb, depth: .u8)
        let a = pixel(doc, "Selected lower", rect(0, 0, 8, 8), SIMD4(1, 0, 0, 1))
        let b = pixel(doc, "Selected upper", rect(8, 0, 16, 8), SIMD4(0, 0, 1, 1))
        let keepA = pixel(doc, "Keep lower", rect(0, 8, 8, 16), SIMD4(0, 1, 0, 1))
        let keepB = pixel(doc, "Keep upper", rect(8, 8, 16, 16), SIMD4(1, 1, 0, 1))
        let lower = Layer.group("Lower parent", [a, keepA])
        let upper = Layer.group("Upper parent", [b, keepB])
        doc.layers = [lower, upper]
        let original = doc
        let s = try selectedSession(doc, [b.id, a.id])
        let before = try F.flat(s)
        let so = try F.convert(s)
        let d = try #require(s.active?.doc)
        #expect(d.layers.map(\.id) == [lower.id, upper.id])
        #expect(d.layer(lower.id)?.children?.map(\.id) == [keepA.id])
        #expect(d.layer(upper.id)?.children?.map(\.id) == [so, keepB.id])
        #expect(d.layer(keepA.id) == keepA)
        #expect(d.layer(keepB.id) == keepB)
        #expect(try F.flat(s) == before)
        let inner = try contents(s)
        #expect(inner.layer(a.id) != nil && inner.layer(b.id) != nil)
        #expect(s.undo())
        #expect(s.active?.doc == original)
    }

    @Test func explicitLayerConvertsOnlyThatLayerDespiteMultiSelection() throws {
        var doc = Document(name: "Explicit", size: PixelSize(width: Int(F.W), height: Int(F.H)), mode: .rgb, depth: .f32)
        let a = pixel(doc, "A", rect(0, 0, 8, 8), SIMD4(1, 0, 0, 1))
        let b = pixel(doc, "B", rect(8, 0, 16, 8), SIMD4(0, 0, 1, 1))
        doc.layers = [a, b]
        let s = try selectedSession(doc, [a.id, b.id])
        try s.execute("layer.smartObjects.convertToSmartObject", ["layer": .id(a.id)])
        #expect(s.active?.doc.layers.count == 2)
        #expect(s.active?.doc.layer(b.id) == b)
        let inner = try contents(s)
        #expect(inner.layers.count == 1)
        #expect(inner.layers.first?.id == a.id)
    }

    @Test func combinedContentsSurviveNativeAndPSDSaveOpen() throws {
        let dir = try F.dir("pair")
        defer { try? FileManager.default.removeItem(at: dir) }
        for depth in SampleType.allCases {
            var doc = Document(name: "Saved pair", size: PixelSize(width: Int(F.W), height: Int(F.H)), mode: .rgb, depth: depth)
            let a = pixel(doc, "Bottom", rect(-2, 4, 20, 20), SIMD4(1, 0, 0, 1))
            let b = pixel(doc, "Top", rect(10, 8, 24, 24), SIMD4(0, 0, 1, 1))
            doc.layers = [a, b]
            let s = try selectedSession(doc, [a.id, b.id])
            let id = try F.convert(s)
            let original = try #require(s.active?.doc)
            let nativeBack = try PcraftFormat.load(try PcraftFormat.save(original))
            let (x, y) = (try F.smart(original, id), try F.smart(nativeBack, id))
            #expect(x.source == y.source && x.transform == y.transform && x.smartFilters == y.smartFilters && x.contentsId == y.contentsId)
            let psd = try EngineIO.export(original, as: "pair.psd", services: s.services)
            let url = dir.appendingPathComponent("pair-\(depth).psd")
            try Data(psd.bytes).write(to: url)
            dropForOracle(url, as: "smart-combinedContents-\(depth).psd")
            let back = try EngineIO.importFile(name: "pair.psd", bytes: psd.bytes, services: s.services).document
            #expect(back.depth == depth)
            #expect(back.layers.count == 1)
            guard case .smart(let sm)? = back.layers.first?.content else { Issue.record("PSD lost the smart object"); continue }
            let (name, bytes) = try #require(SmartCommands.sourceBytes(back.metadata, sm.source, fs: s.services.fileSystem))
            let inner = try SmartCommands.decodeSource(name, bytes, services: s.services)
            let names = inner.walk().filter { if case .raster = $0.layer.content { true } else { false } }.map(\.layer.name)
            #expect(names == ["Bottom", "Top"], "\(depth)")
        }
    }

    @Test func selectedAncestorInAnotherParentCannotRemoveTheNewSmartObject() throws {
        var doc = Document(name: "Ancestor", size: PixelSize(width: Int(F.W), height: Int(F.H)), mode: .rgb, depth: .u8)
        let a = pixel(doc, "A", rect(0, 0, 8, 8), SIMD4(1, 0, 0, 1))
        let b = pixel(doc, "B", rect(8, 0, 16, 8), SIMD4(0, 0, 1, 1))
        let keep = pixel(doc, "Unselected sibling", rect(0, 8, 8, 16), SIMD4(0, 1, 0, 1))
        let lower = Layer.group("Selected parent", [a])
        let upper = Layer.group("Unselected parent", [b, keep])
        doc.layers = [lower, upper]
        let s = try selectedSession(doc, [lower.id, a.id, b.id])
        let so = try F.convert(s)
        let outer = try #require(s.active?.doc)
        #expect(outer.layers.map(\.id) == [upper.id])
        #expect(outer.layer(upper.id)?.children?.map(\.id) == [so, keep.id])
        #expect(outer.layer(keep.id) != nil)
        let inner = try contents(s)
        #expect(inner.layer(lower.id) != nil && inner.layer(a.id) != nil && inner.layer(b.id) != nil)
        #expect(inner.layer(keep.id) == nil)
    }

    @Test func anAllHiddenSelectionIsRejectedWithoutChangingDocumentSelectionOrHistory() throws {
        var doc = Document(name: "Hidden pair", size: PixelSize(width: Int(F.W), height: Int(F.H)), mode: .rgb, depth: .u8)
        var a = pixel(doc, "Hidden A", rect(0, 0, 8, 8), SIMD4(1, 0, 0, 1))
        var b = pixel(doc, "Hidden B", rect(8, 0, 16, 8), SIMD4(0, 0, 1, 1))
        a.visible = false
        b.visible = false
        let ids = [a.id, b.id]
        doc.layers = [a, b]
        let original = doc
        let s = try selectedSession(doc, ids)
        do {
            try s.execute("layer.smartObjects.convertToSmartObject")
            Issue.record("an all-hidden selection is empty")
        } catch {
            #expect("\(error)".contains("empty"), "\(error)")
        }
        #expect(s.active?.doc == original)
        #expect(s.active?.selectedLayers == ids)
        #expect(s.active?.activeLayer == ids[1])
        #expect(s.active?.history.pastCount == 0)
        #expect(!s.undo())
    }
}

@Suite struct SmartStackCacheTests {
    typealias F = SmartFixture

    @Test func stagesTrimForMemoryPressure() throws {
        let key: SmartCommands.StackCache.Key = Array("memory-pressure trim test".utf8)
        var surface = Surface(format: PixelFormat(mode: .rgb, sample: .u8, alpha: true))
        surface.fill(PixelRect(x: 0, y: 0, width: 300, height: 300), with: [1, 0, 0, 1])
        SmartCommands.StackCache.put(key, .init(surface: surface, extent: surface.contentBounds))
        #expect(SmartCommands.StackCache.get(key) != nil)
        #expect(MemoryPressureRelay.shared.registered.contains("smart-object stages"))
        #expect(SmartCommands.StackCache.trim(.critical) >= SmartCommands.StackCache.surfaceBytes(surface))
        #expect(SmartCommands.StackCache.get(key) == nil)
    }

    /// A smart object with three smart filters, the middle one blended at half opacity.
    func filtered(_ depth: Int) throws -> Session {
        let s = try F.session(depth)
        try F.paint(s)
        try s.execute("filter.convertForSmartFilters")
        try s.execute("filter.blur.gaussianBlur", ["radius": 2])
        try s.execute("filter.noise.addNoise", ["amount": 20, "distribution": "gaussian", "seed": 5])
        try s.execute("filter.blur.motionBlur", ["angle": 30, "distance": 6])
        try s.execute("layer.smartFilter.blendingOptions", ["index": 1, "blend": "multiply", "opacity": 0.5])
        return s
    }

    /// The active smart object rendered without the stage cache.
    func uncached(_ s: Session) throws -> Surface {
        let doc = try #require(s.active?.doc)
        let sm = try F.activeSmart(s)
        let (name, bytes) = try #require(SmartCommands.sourceBytes(doc.metadata, sm.source, fs: s.services.fileSystem))
        let placed = try SmartCommands.place(name, bytes, doc.pixelFormat, sm, services: s.services)
        return SmartCommands.applySmartFilters(placed, sm, canvas: doc.bounds, fs: s.services.fileSystem)
    }

    @Test func rendersFromCachedStagesMatchFullRendersAtEveryDepth() throws {
        for depth in F.depths {
            let s = try filtered(depth)
            let edits: [(String, JSONValue)] = [
                ("layer.smartFilter.setVisible", ["index": 2, "visible": false]),
                ("layer.smartFilter.setVisible", ["index": 2, "visible": true]),
                ("layer.smartFilter.setVisible", ["index": 0, "visible": false]),
                ("layer.smartFilter.setVisible", ["index": 0, "visible": true]),
                ("layer.smartFilter.setParams", ["index": 2, "params": ["distance": 9]]),
                ("layer.smartFilter.blendingOptions", ["index": 1, "opacity": 0.8]),
                ("layer.smartFilter.move", ["index": 0, "to": 2]),
                ("layer.smartFilter.disableSmartFilters", ["enabled": false]),
                ("layer.smartFilter.disableSmartFilters", ["enabled": true]),
                ("layer.smartFilter.delete", ["index": 1]),
            ]
            for (id, params) in edits {
                try s.execute(id, params)
                #expect(try F.activeSmart(s).cache == uncached(s), "\(id) \(params) at \(depth)-bit")
            }
        }
    }

    @Test func aCancelledRenderStopsBeforeAnUncachedFilter() throws {
        let s = try filtered(8)
        var sm = try F.activeSmart(s)
        // A radius no other render uses, so the stack below it is cached but this stage isn't.
        if case .object(var p) = sm.smartFilters[0].params {
            p["radius"] = 2.375
            sm.smartFilters[0].params = .object(p)
        }
        let ctx = JobContext()
        ctx.cancel()
        do {
            _ = try SmartCommands.renderIn(try #require(s.active?.doc), sm, ctx: ctx, services: s.services)
            Issue.record("a cancelled render stops")
        } catch EngineError.cancelled {}
    }

    @Test func badSmartFilterEditsFailAtOnceWithStart() throws {
        let s = try filtered(8)
        let before = try F.activeSmart(s)
        do {
            _ = try s.start("layer.smartFilter.setVisible", ["index": 9])
            Issue.record("a bad index fails at once")
        } catch EngineError.badParams {}
        #expect(try F.activeSmart(s) == before)
    }
}
