// Port of photocraft-engine's session-level tests (crates/engine/src/jobs_tests.rs, tests.rs: journal, damage, coalescing, enablement; prefs/tests.rs) plus the architecture-§4/§6 seams the native port adds (events, snapshots, transactions and rebase, view-models, thumbnails, glue), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import Metal
import PCDocument
@testable import PCEngine
import PCFoundation
import PCHistory
import PCIntelligence
import PCPlatform
import PCRender
import Synchronization
import Testing

/// A registry with a slow, cancellable document-editing job (photocraft's jobs_tests fake job).
func registryWithSlowJob() -> CommandRegistry {
    var r = CommandRegistry.standard()
    r.add(CommandSpec("test.slowFill", "Slow Fill", params: #"{"ms":int=200}"#, module: "test", enabled: Pre.hasPixelLayer) { s, p in
        let ms = p["ms"]?.intValue ?? 200
        guard let id = s.active?.activeLayer else { throw EngineError.other("no active layer") }
        return try s.editJob("Slow Fill", { doc, _, ctx in
            for i in 0..<20 {
                try ctx.check()
                ctx.progress(Float(i) / 20, "filling")
                Thread.sleep(forTimeInterval: Double(ms) / 20_000)
            }
            doc.withRaster(of: id) { $0.fill(PixelRect(x: 0, y: 0, width: 4, height: 4), with: [0, 1, 0, 1]) }
            return 7
        }, finish: { n in ["value": .int(n)] })
    })
    return r
}

@Suite struct JobTests {
    func session() throws -> Session {
        let s = Session(registry: registryWithSlowJob())
        try s.execute("file.new", ["width": 16, "height": 16])
        try s.execute("layer.new.layer", .object([:]))
        return s
    }

    @Test func inlineExecuteRunsJobsSynchronously() throws {
        let s = try session()
        let n = s.active!.history.entries.count
        let r = try s.execute("test.slowFill", ["ms": 20])
        #expect(r["value"]?.intValue == 7)
        #expect(s.active!.history.entries.count == n + 1)
        #expect(s.journal.last?.id == "test.slowFill")
    }

    @Test func backgroundJobLocksTheDocumentAndAppliesAsOneStep() throws {
        let s = try session()
        let n = s.active!.history.entries.count
        guard case .job(let id) = try s.start("test.slowFill", ["ms": 300]) else { Issue.record("expected a job"); return }
        #expect(s.hasJobs)
        let reason = try #require(s.disabledReason("layer.new.layer"))
        #expect(reason.contains("Slow Fill"))
        #expect(s.isEnabled("tools.swapColors"))
        #expect(!s.undo())
        let r = try s.waitJob(id)
        #expect(r["value"]?.intValue == 7)
        #expect(!s.hasJobs)
        #expect(s.active!.history.entries.count == n + 1)
        let px = s.active!.doc.layer(s.active!.activeLayer!)!.rasterSurface!.pixel(x: 1, y: 1)
        #expect(px == [0, 1, 0, 1])
        #expect(s.jobsWithRecent.last?.state == "done")
    }

    @Test func cancellingLeavesTheDocumentUnchanged() throws {
        let s = try session()
        let before = s.active!.doc
        guard case .job(let id) = try s.start("test.slowFill", ["ms": 2000]) else { Issue.record("expected a job"); return }
        #expect(s.cancelJob(id))
        #expect(throws: EngineError.cancelled) { try s.waitJob(id) }
        #expect(s.active!.doc == before)
        #expect(s.isEnabled("layer.new.layer"))
    }

    @Test func aJobRebasesOntoADocumentThatChangedMeanwhile() throws {
        let s = try session()
        let fillLayer = s.active!.activeLayer!
        guard case .job(let id) = try s.start("test.slowFill", ["ms": 200]) else { Issue.record("expected a job"); return }
        // An edit that bypasses the job lock (a host calling the API directly): rename the layer.
        try s.edit("Rename") { doc, _ in doc.updateLayer(fillLayer) { $0.name = "Renamed" } }
        _ = try s.waitJob(id)
        let l = try #require(s.active!.doc.layer(fillLayer))
        #expect(l.name == "Renamed")
        #expect(l.rasterSurface!.pixel(x: 1, y: 1) == [0, 1, 0, 1])
    }

    @Test func asyncExecutionAwaitsWithoutBlocking() async throws {
        let s = try session()
        let r = try await s.executeAsync("test.slowFill", ["ms": 40])
        #expect(r["value"]?.intValue == 7)
    }

    @Test func jobsListAndCancelCommands() throws {
        let s = try session()
        _ = try s.start("test.slowFill", ["ms": 2000])
        let list = try s.execute("jobs.list")
        #expect(list["jobs"]?.arrayValue?.first?["state"] == "running")
        #expect(try s.execute("jobs.cancel")["cancelled"]?.intValue == 1)
    }
}

@Suite struct SessionSeamTests {
    @Test func eventsReportChangesWithDamage() async throws {
        let s = Session()
        let stream = s.events()
        try s.execute("file.new", ["width": 300, "height": 300, "background": "transparent"])
        try s.execute("select.all")
        try s.execute("layer.setProps", ["name": "Renamed"])
        var events: [SessionEvent] = []
        for await e in stream {
            events.append(e)
            if case .commandFinished(id: "layer.setProps", _) = e { break }
        }
        #expect(events.contains { if case .documentOpened = $0 { true } else { false } })
        // Select All and a rename change no pixels.
        let damages = events.compactMap { e -> PixelRect?? in if case .documentChanged(_, _, let d) = e { d } else { nil } }
        #expect(damages.count == 2)
        #expect(damages.allSatisfy { $0 == .some(.empty) })
    }

    @Test func snapshotsAreReadableFromAnotherThread() async throws {
        let s = Session()
        try s.execute("file.new", ["width": 8, "height": 8])
        try s.execute("layer.new.layer", ["name": "Top"])
        let store = s.snapshots
        let name = await Task.detached { store.active?.doc.layers.last?.name }.value
        #expect(name == "Top")
        #expect(store.active?.revision == s.active?.revision)
    }

    @Test func viewModelsDescribeThePanels() throws {
        let s = Session()
        try s.execute("file.new", ["width": 32, "height": 32])
        try s.execute("layer.new.group", ["name": "G"])
        try s.execute("layer.new.layer", ["name": "In"])
        try s.execute("layer.newAdjustmentLayer.hueSaturation", ["hue": 30])
        try s.execute("layer.layerMask.revealAll", .object([:]))
        let vm = try #require(s.viewModels())
        // New layers go above the active layer as its sibling (photocraft `insert_above`).
        #expect(vm.layers.rows.map(\.name) == ["Hue/Saturation 1", "In", "G", "Background"])
        #expect(vm.layers.rows.map(\.depth) == [0, 0, 0, 0])
        #expect(vm.layers.rows.first { $0.name == "Background" }?.isBackground == true)
        #expect(vm.layers.rows.first { $0.name == "Hue/Saturation 1" }?.active == true)
        #expect(vm.history.rows.last?.current == true)
        #expect(vm.history.canUndo)
        #expect(vm.properties.section == .adjustment)
        #expect(vm.properties.values["kind"] == "hueSaturation")
        #expect(vm.channels.rows.map(\.name).prefix(4) == ["RGB", "Red", "Green", "Blue"])
        #expect(s.undo())
        let vm2 = try #require(s.viewModels())
        #expect(vm2.history.rows.last?.undone == true)
    }

    @Test func thumbnailsAreKeyedByTileGenerations() throws {
        let s = Session()
        try s.execute("file.new", ["width": 64, "height": 32, "background": "transparent"])
        let cache = ThumbnailCache()
        let st = try #require(s.active)
        let l = try #require(st.doc.layer(st.activeLayer!))
        let h1 = ThumbnailCache.handle(doc: st.doc, layer: l)
        let t1 = try cache.thumbnail(h1, in: st.doc, maxSide: 16)
        #expect(t1.width == 16 && t1.height == 8)
        #expect(t1.rgba8[3] == 0)
        try s.edit("paint") { doc, a in doc.withRaster(of: a!) { $0.fill(PixelRect(x: 0, y: 0, width: 64, height: 32), with: [1, 0, 0, 1]) } }
        let st2 = try #require(s.active)
        let h2 = ThumbnailCache.handle(doc: st2.doc, layer: st2.doc.layer(st2.activeLayer!)!)
        #expect(h2 != h1)
        let t2 = try cache.thumbnail(h2, in: st2.doc, maxSide: 16)
        #expect(t2.rgba8[0] == 255 && t2.rgba8[3] == 255)
        // An edit elsewhere (a new layer) leaves this layer's handle as it was.
        try s.execute("layer.new.layer")
        let st3 = try #require(s.active)
        #expect(ThumbnailCache.handle(doc: st3.doc, layer: st3.doc.layer(st2.activeLayer!)!) == h2)
        #expect(cache.count == 2)
    }

    @Test func transactionsAreFineGrainedAndRebaseByLayerId() throws {
        let s = Session()
        try s.execute("file.new", ["width": 300, "height": 300])
        let bg = s.active!.activeLayer!
        try s.execute("select.rect", ["x": 0, "y": 0, "width": 10, "height": 10])
        try s.execute("image.adjustments.invert")
        let t = try #require(s.active?.lastTransaction)
        guard case .paintTiles(.layer(let id), let patches)? = t.ops.first else { Issue.record("expected paintTiles: \(t.ops)"); return }
        #expect(id == bg)
        #expect(patches.count == 1)
        // The damage is the changed pixels, not the whole patched tile.
        #expect(s.active?.lastDamage == PixelRect(x: 0, y: 0, width: 10, height: 10))
        // The same transaction rebases onto a document that gained a layer meanwhile.
        var other = s.active!.history.state(s.active!.history.pastCount - 1)!
        try other.insert(.raster("New", format: other.pixelFormat), at: .top(of: nil))
        _ = try t.apply(to: &other)
        #expect(other.layer(bg)?.rasterSurface?.pixel(x: 1, y: 1) == [0, 0, 0, 1])
        #expect(other.layers.count == 2)
    }

    @Test func paramNotationBecomesASchema() {
        let s = ParamSchema.schema(##"{"width":1..300000=1920,"mode":"rgb|gray|cmyk|lab"="rgb","depth":8|16|32=8,"layer":id?,"name":str,"antiAlias":bool=true,"color":"#rrggbb"=foreground,"feather":px=0} (note)"##)
        let p = s["properties"]!
        #expect(p["width"]?["type"] == "integer" && p["width"]?["maximum"]?.intValue == 300_000 && p["width"]?["default"]?.intValue == 1920)
        #expect(p["mode"]?["enum"]?.arrayValue?.count == 4 && p["mode"]?["default"] == "rgb")
        #expect(p["depth"]?["enum"]?.arrayValue?.count == 3)
        #expect(p["layer"]?["type"] == "integer" && p["layer"]?["x-optional"] == true)
        #expect(p["name"]?["type"] == "string")
        #expect(p["antiAlias"]?["type"] == "boolean" && p["antiAlias"]?["default"] == true)
        #expect(p["color"]?["type"] == "string")
        #expect(s["description"] == "(note)")
        // Every registered command has an object schema.
        for spec in CommandRegistry.standard().specs { #expect(spec.schema["type"] == "object", "\(spec.id)") }
    }

    @Test func preferencesValidateAndApplyHistoryLimits() throws {
        let s = Session()
        try s.execute("file.new", ["width": 8, "height": 8])
        #expect(try s.execute("prefs.get", ["path": "performance.historyStates"]).intValue == 50)
        try s.execute("prefs.set", ["path": "performance.historyStates", "value": 3])
        #expect(s.active?.history.maxStates == 3)
        #expect(throws: EngineError.self) { try s.execute("prefs.set", ["path": "performance.historyStates", "value": "lots"]) }
        #expect(throws: EngineError.self) { try s.execute("prefs.set", ["path": "nope.key", "value": 1]) }
        for _ in 0..<5 { try s.execute("layer.new.layer") }
        #expect(s.active!.history.pastCount == 3)
        try s.execute("prefs.reset", ["path": "performance"])
        #expect(s.preferences.historyStates == 50)
        let r = try s.execute("edit.keyboardShortcuts", ["set": ["layer.new.group": "Cmd+Shift+G"], "list": true, "filter": "layer.new.group"])
        #expect(r["shortcuts"]?[0]?["shortcut"] == "Cmd+Shift+G")
    }
}

@Suite struct GlueTests {
    @Test func colorSyncBacksCMYK() {
        #expect(ColorSetup.ensureInstalled())
        #expect(ColorManagement.installed != nil)
    }

    @Test func typeAndShapeLayersRenderThroughThePlatformRasterizer() throws {
        let s = Session()
        try s.execute("file.new", ["width": 120, "height": 60, "background": "white"])
        try s.edit("Add layers") { doc, active in
            var t = TextLayer()
            t.text = "HH"
            t.fontFamily = "Helvetica"
            t.sizePt = 40
            t.color = .black
            t.transform = .translate(10, 45)
            active = doc.insertAbove(active, Layer(name: "Type", content: .text(t)))
            let sq = VectorPath([Subpath.polygon([(80, 10), (110, 10), (110, 40), (80, 40)]).withOp(.combine)])
            var sh = ShapeLayer(path: sq, fill: .solid(.rgb(1, 0, 0)))
            sh.cache = nil
            active = doc.insertAbove(active, Layer(name: "Shape", content: .shape(sh)))
        }
        let doc = s.active!.doc
        let r = EngineRenderer.shared
        // The shape is red inside its square.
        let inside = try r.pixel(doc, x: 95, y: 25)
        #expect(inside.x > 0.99 && inside.y < 0.01)
        // The type put ink somewhere in its box.
        let buf = try r.render(doc, region: PixelRect(x: 0, y: 0, width: 75, height: 60))
        #expect(buf.px.contains { $0.x < 0.2 })
        #expect(r.rasterizer.misses.isEmpty)
    }

    @Test func vectorMasksUseCoreGraphicsCoverage() throws {
        let s = Session()
        try s.execute("file.new", ["width": 40, "height": 40, "background": "white"])
        try s.edit("Masked") { doc, active in
            var l = Layer.raster("Black", format: doc.pixelFormat)
            l.withRaster { $0.fill(PixelRect(x: 0, y: 0, width: 40, height: 40), with: [0, 0, 0, 1]) }
            l.vectorMask = VectorMask(path: VectorPath([Subpath.polygon([(0, 0), (20, 0), (20, 40), (0, 40)])]))
            active = doc.insertAbove(active, l)
        }
        let doc = s.active!.doc
        #expect(try EngineRenderer.shared.pixel(doc, x: 5, y: 5).x < 0.01)
        #expect(try EngineRenderer.shared.pixel(doc, x: 30, y: 5).x > 0.99)
    }

    @Test func displayColorBuildsLUTsOnlyWhenNeeded() throws {
        var doc = Document(name: "d", size: PixelSize(width: 4, height: 4), mode: .rgb, depth: .u8)
        let dc = DisplayColor()
        let srgb = BuiltinProfile.srgb.profile
        let same = try dc.canvasDisplay(for: doc, monitor: srgb)
        #expect(same.isIdentity)
        let p3 = try dc.canvasDisplay(for: doc, monitor: BuiltinProfile.displayP3.profile)
        #expect(!p3.isIdentity)
        // sRGB red is inside P3: less saturated there.
        let red = p3.apply(RGBABuffer(rect: PixelRect(x: 0, y: 0, width: 1, height: 1), px: [SIMD4(1, 0, 0, 1)])).px[0]
        #expect(red.x < 0.95 && red.y > 0.1)
        var proof = ProofView()
        proof.enabled = true
        #expect(!(try dc.canvasDisplay(for: doc, monitor: srgb, proof: proof)).isIdentity)
        if let device = MTLCreateSystemDefaultDevice() {
            #expect(p3.renderLUT(device: device)?.size == 33)
        }
        doc.mode = .grayscale
        #expect(try dc.canvasDisplay(for: doc, monitor: srgb).source.colorSpace == .gray)
    }

    @Test func intelligenceCommandsAreRegisteredFromTheDescriptors() throws {
        let s = Session()
        for d in IntelligenceCommands.all { #expect(s.registry.spec(d.id)?.isAvailable == true, "\(d.id)") }
        #expect(s.disabledReason("select.subject") == "no document open")
        try s.execute("file.new", ["width": 32, "height": 32])
        #expect(s.disabledReason("edit.contentAwareFill") == "make a selection first")
    }

    @Test func contentAwareFillRunsAsABackgroundJobAndUndoesInOneStep() throws {
        let s = Session()
        try s.execute("file.new", ["width": 64, "height": 64, "background": "transparent"])
        try s.edit("Gradient") { doc, a in
            doc.withRaster(of: a!) { sf in
                var px = [Float](repeating: 0, count: 64 * 64 * 4)
                for y in 0..<64 { for x in 0..<64 { let i = (y * 64 + x) * 4; px[i] = Float(x) / 63; px[i + 1] = Float(y) / 63; px[i + 2] = 0.5; px[i + 3] = 1 } }
                sf.writeRegion(PixelRect(x: 0, y: 0, width: 64, height: 64), px)
            }
        }
        try s.edit("Hole") { doc, a in doc.withRaster(of: a!) { $0.fill(PixelRect(x: 28, y: 28, width: 8, height: 8), with: [1, 1, 1, 1]) } }
        try s.execute("select.rect", ["x": 26, "y": 26, "width": 12, "height": 12])
        let n = s.active!.history.entries.count
        guard case .job(let id) = try s.start("edit.contentAwareFill") else { Issue.record("expected a job"); return }
        let r = try s.waitJob(id)
        #expect(r["filled"] == true)
        // PCAlgo's PatchMatch is the default classical inpaint tier.
        #expect(r["tier"] == "classical")
        #expect(r["engine"]?.stringValue?.contains("PatchMatch") == true, "\(r)")
        #expect(s.active!.history.entries.count == n + 1)
        let c = s.active!.doc.layer(s.active!.activeLayer!)!.rasterSurface!.rgba(x: 32, y: 32)
        #expect(abs(c.x - 0.5) < 0.2 && abs(c.y - 0.5) < 0.2, "filled from the gradient around: \(c)")
        #expect(s.undo())
        #expect(s.active!.doc.layer(s.active!.activeLayer!)!.rasterSurface!.rgba(x: 32, y: 32) == SIMD4(1, 1, 1, 1))
    }

    @Test func contentAwareFillHonoursPatchMatchOptions() throws {
        func run(_ extra: JSONValue) throws -> [Float] {
            let s = Session()
            try s.execute("file.new", ["width": 64, "height": 64, "background": "transparent"])
            try s.edit("Noise") { doc, a in
                doc.withRaster(of: a!) { sf in
                    var px = [Float](repeating: 0, count: 64 * 64 * 4)
                    var h: UInt32 = 7
                    for i in stride(from: 0, to: px.count, by: 4) {
                        for k in 0..<3 { h = h &* 1_664_525 &+ 1_013_904_223; px[i + k] = Float(h >> 8) / Float(1 << 24) }
                        px[i + 3] = 1
                    }
                    sf.writeRegion(PixelRect(x: 0, y: 0, width: 64, height: 64), px)
                }
            }
            try s.execute("select.rect", ["x": 24, "y": 24, "width": 16, "height": 16])
            let base: JSONValue = ["sampling": "rectangular", "margin": 12]
            try s.execute("edit.contentAwareFill", base.merging(extra))
            return s.active!.doc.layer(s.active!.activeLayer!)!.rasterSurface!.readRegion(PixelRect(x: 24, y: 24, width: 16, height: 16))
        }
        let a = try run(["seed": 1]), b = try run(["seed": 1])
        #expect(a == b, "a seeded fill is reproducible")
        #expect(try run(["seed": 2]) != a, "the seed reaches PatchMatch")
        #expect(try run(["seed": 1, "colorAdaptation": "veryHigh", "mirror": true]) != a, "the adaptation options reach PatchMatch")
    }
}
