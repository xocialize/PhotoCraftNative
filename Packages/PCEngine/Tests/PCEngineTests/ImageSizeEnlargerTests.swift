// Image Size's enlarger slot (AB-T-0292): the chain's arithmetic (AB-D-0119), a fake ×2 that marks what it
// touched (each pixel layer, never a mask or a smart object's source), the fallbacks to the Resample alone (a
// target smaller on one axis, an empty, emptied or unavailable slot), and the job path the editor runs it on
// (`executeAsync` from the main actor with a provider that hops to it, `start` + cancel). MIT OR Apache-2.0,
// © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import PCDocument
@testable import PCEngine
import PCFoundation
import PCIntelligence
import Synchronization
import Testing

/// The calls a fake enlarger saw: each input's rect and format.
final class EnlargeLog: Sendable {
    let calls = Mutex<[(rect: PixelRect, format: PixelFormat)]>([])
    func add(_ r: PixelRect, _ f: PixelFormat) { calls.withLock { $0.append((r, f)) } }
    var all: [(rect: PixelRect, format: PixelFormat)] { calls.withLock { $0 } }
}

/// Nearest ×2 that adds 0.25 to green wherever there is colour: its pixels are told apart from any Resample's.
struct MarkingEnlarger: ImageEnlarger {
    var name = "Marker"
    let log: EnlargeLog
    var delay: Duration? = nil
    var hopsToMain = false
    var wrongFormat = false

    func enlarge(_ surface: Surface, rect r: PixelRect) async throws -> Surface {
        log.add(r, surface.format)
        if hopsToMain { await MainActor.run { _ = Thread.isMainThread } }
        if let delay { try await Task.sleep(for: delay) }
        let src = surface.readRGBA(r)
        let (w, h) = (r.width, r.height)
        var px = [SIMD4<Float>](repeating: .zero, count: 4 * w * h)
        for y in 0..<(2 * h) {
            for x in 0..<(2 * w) {
                var p = src[(y / 2) * w + x / 2]
                if p.w > 0 { p.y = min(p.y + 0.25, 1) }
                px[y * 2 * w + x] = p
            }
        }
        let format = wrongFormat ? PixelFormat(mode: .grayscale, sample: surface.format.sample, alpha: false) : surface.format
        var out = Surface(format: format, defaultPixel: wrongFormat ? [0] : surface.defaultPixelValue)
        out.writeRGBA(PixelRect(x0: r.x0 * 2, y0: r.y0 * 2, x1: r.x1 * 2, y1: r.y1 * 2), px)
        return out
    }
}

@Suite struct ImageSizeEnlargerTests {
    typealias Plan = ImageCommands.EnlargerPlan

    struct Scene {
        let s: Session
        let log: EnlargeLog
        /// A red square (10, 5)–(20, 15) with a reveal-all mask.
        let a: LayerId
        /// Inside a group: a green pixel block (30, 2)–(34, 6).
        let grouped: LayerId
        /// A smart object made from a blue square (2, 12)–(8, 18).
        let smart: LayerId
    }

    /// 40 × 20, white Background; the layers `Scene` names. `register: false` leaves the slot empty.
    func scene(depth: Int = 8, register: Bool = true, provider: ((EnlargeLog) -> any ImageEnlarger)? = nil) throws -> Scene {
        let log = EnlargeLog()
        let services = EngineServices()
        if register { services.intelligence.registry.register(enlarger: provider?(log) ?? MarkingEnlarger(log: log)) }
        let s = Session(services: services)
        try s.execute("file.new", ["width": 40, "height": 20, "depth": .int(depth), "background": "white"])
        func paint(_ r: PixelRect, _ c: [Float]) throws -> LayerId {
            try s.execute("layer.new.layer")
            let id = s.active!.activeLayer!
            try s.edit("paint") { doc, _ in doc.withRaster(of: id) { $0.writeRGBA(r, [SIMD4<Float>](repeating: SIMD4(c[0], c[1], c[2], 1), count: r.area)) } }
            return id
        }
        let smart0 = try paint(PixelRect(x0: 2, y0: 12, x1: 8, y1: 18), [0, 0, 1])
        try s.execute("layer.smartObjects.convertToSmartObject", ["layer": .id(smart0)])
        let smart = s.active!.activeLayer!
        let grouped = try paint(PixelRect(x0: 30, y0: 2, x1: 34, y1: 6), [0, 1, 0])
        try s.execute("layer.groupLayers", ["layer": .id(grouped)])
        let a = try paint(PixelRect(x0: 10, y0: 5, x1: 20, y1: 15), [1, 0, 0])
        try s.edit("mask") { doc, _ in doc.updateLayer(a) { $0.mask = .revealAll() } }
        return Scene(s: s, log: log, a: a, grouped: grouped, smart: smart)
    }

    func layer(_ s: Session, _ id: LayerId) -> Layer { s.active!.doc.layer(id)! }
    func rgba(_ s: Session, _ id: LayerId, _ x: Int32, _ y: Int32) -> SIMD4<Float> { layer(s, id).surface!.rgba(x: x, y: y) }

    // MARK: The chain's arithmetic

    @Test func theChainTakesTheFewestPassesThatReachTheTarget() {
        let size = PixelSize(width: 64, height: 48)
        func plan(_ w: Int, _ h: Int, budget: UInt64 = ImageCommands.maxResampleBytes) -> Plan? {
            Plan.plan(from: size, to: PixelSize(width: w, height: h), bytesPerPixel: 4, budget: budget)
        }
        // ×2 exactly: one pass, nothing to fit.
        let x2 = plan(128, 96)
        #expect(x2 == Plan(passes: 1, intermediate: PixelSize(width: 128, height: 96), fitsUp: false))
        #expect(x2?.lands(on: PixelSize(width: 128, height: 96)) == true)
        // ×4 exactly.
        #expect(plan(256, 192) == Plan(passes: 2, intermediate: PixelSize(width: 256, height: 192), fitsUp: false))
        // ×2.5: two passes to ×4, then the fit reduces to the exact size.
        let x25 = plan(160, 120)
        #expect(x25 == Plan(passes: 2, intermediate: PixelSize(width: 256, height: 192), fitsUp: false))
        #expect(x25?.lands(on: PixelSize(width: 160, height: 120)) == false)
        // One pixel past ×2 on one axis takes a second pass.
        #expect(plan(129, 60)?.passes == 2)
        // A stretched target: both axes must reach it.
        #expect(plan(70, 190)?.intermediate == PixelSize(width: 256, height: 192))
        // Smaller or equal on either axis: the Resample alone.
        for (w, h) in [(64, 100), (100, 48), (50, 100), (100, 30), (64, 48), (32, 24)] { #expect(plan(w, h) == nil, "\(w)×\(h)") }
    }

    @Test func theBudgetCutsThePassesShortAndTheFitEnlarges() {
        let size = PixelSize(width: 64, height: 48)
        // 128×96×4 bytes fits, 256×192×4 does not: one pass, then the fit enlarges the rest (AB-D-0119's fallback).
        let one = Plan.plan(from: size, to: PixelSize(width: 200, height: 150), bytesPerPixel: 4, budget: 128 * 96 * 4)
        #expect(one == Plan(passes: 1, intermediate: PixelSize(width: 128, height: 96), fitsUp: true))
        // Not even ×2 fits: no pass.
        #expect(Plan.plan(from: size, to: PixelSize(width: 100, height: 80), bytesPerPixel: 4, budget: 1000)?.passes == 0)
        // The pass cap: 1 px to 1000 px stops at ×256 and fits up.
        let capped = Plan.plan(from: PixelSize(width: 1, height: 1), to: PixelSize(width: 1000, height: 1000), bytesPerPixel: 4)
        #expect(capped == Plan(passes: Plan.maxPasses, intermediate: PixelSize(width: 256, height: 256), fitsUp: true))
    }

    // MARK: What the provider touches

    @Test func theProviderRunsOnEachPixelLayerAndNotOnMasksOrSmartObjects() throws {
        let sc = try scene()
        let s = sc.s
        let past = s.active!.history.pastCount
        let format = s.active!.doc.pixelFormat
        let r = try s.execute("image.imageSize", ["width": 80, "height": 40, "enlarger": true, "resample": "lanczos"])
        #expect(s.active!.doc.size == PixelSize(width: 80, height: 40))
        #expect(r["width"] == 80 && r["height"] == 40)
        let e = try #require(r["enlarger"])
        #expect(e["used"] == true && e["passes"] == 1 && e["fit"] == "none" && e["engine"] == "Marker", "\(e)")
        #expect(e["chain"] == "Marker ×2", "\(e)")

        // Every call was a pixel layer's colour, at the document's format: never a 1-channel mask, never a
        // smart object's source (its blue square's rect is not among them).
        let calls = sc.log.all
        #expect(calls.allSatisfy { $0.format == format }, "\(calls.map(\.format))")
        let rects = Set(calls.map(\.rect))
        #expect(rects.contains(PixelRect(x0: 10, y0: 5, x1: 20, y1: 15)))
        #expect(rects.contains(PixelRect(x0: 30, y0: 2, x1: 34, y1: 6)))
        #expect(!rects.contains(PixelRect(x0: 2, y0: 12, x1: 8, y1: 18)))
        #expect(e["layers"]?.intValue == calls.count)

        // The marker is in the pixel layers, exactly (×2 lands on the target: no fit); 8-bit stores 0.25 as 64.
        let marked = rgba(s, sc.a, 30, 20)
        #expect(marked.x == 1 && abs(marked.y - 64 / 255) < 1e-6 && marked.z == 0 && marked.w == 1, "\(marked)")
        #expect(rgba(s, sc.a, 19, 9) == SIMD4(0, 0, 0, 0), "outside the doubled square stays clear")
        #expect(rgba(s, sc.grouped, 64, 8) == SIMD4(0, 1, 0, 1))
        #expect(layer(s, sc.grouped).surface!.contentBounds == PixelRect(x0: 60, y0: 4, x1: 68, y1: 12))
        // The smart object re-rendered from its source: blue, no marker.
        let blue = rgba(s, sc.smart, 10, 30)
        #expect(blue.y < 0.01 && blue.z > 0.99 && blue.w > 0.99, "\(blue)")
        // The mask followed the layer through the ordinary resample.
        let mask = try #require(layer(s, sc.a).mask)
        #expect(mask.surface.format.channels == 1 && mask.surface.defaultPixelValue == [1])

        // One step; Undo puts everything back.
        #expect(s.active!.history.pastCount == past + 1)
        try s.execute("edit.undo")
        #expect(s.active!.doc.size == PixelSize(width: 40, height: 20))
        #expect(rgba(s, sc.a, 15, 10) == SIMD4(1, 0, 0, 1))
    }

    @Test func aTargetBetweenThePassesIsFitByTheChosenResample() throws {
        let sc = try scene()
        let s = sc.s
        let r = try s.execute("image.imageSize", ["width": 100, "height": 50, "enlarger": true, "resample": "bicubic"])
        #expect(s.active!.doc.size == PixelSize(width: 100, height: 50))
        let e = try #require(r["enlarger"])
        #expect(e["passes"] == 2 && e["intermediate"] == [160, 80] && e["fit"] == "bicubic" && e["fitsUp"] == false, "\(e)")
        #expect(e["chain"] == "Marker ×4 (2 passes of ×2) → 100 x 50 (bicubic)", "\(e)")
        // Two passes per pixel layer.
        #expect(sc.log.all.filter { $0.rect == PixelRect(x0: 10, y0: 5, x1: 20, y1: 15) }.count == 1)
        #expect(sc.log.all.filter { $0.rect == PixelRect(x0: 20, y0: 10, x1: 40, y1: 30) }.count == 1)
        // The square's interior carries both passes' marker (64, then 128 of 255) through the fit; it lands at ×2.5.
        let mid = rgba(s, sc.a, 37, 25)
        #expect(abs(mid.x - 1) < 1e-3 && abs(mid.y - 128 / 255) < 1e-3 && mid.z < 1e-3 && abs(mid.w - 1) < 1e-3, "\(mid)")
        let b = layer(s, sc.a).surface!.contentBounds
        #expect(abs(b.x0 - 25) <= 2 && abs(b.x1 - 50) <= 2 && abs(b.y0 - 12) <= 2 && abs(b.y1 - 38) <= 2, "\(b)")
    }

    @Test func automaticFitsAReductionWithBicubicSharper() throws {
        let sc = try scene()
        let r = try sc.s.execute("image.imageSize", ["width": 100, "enlarger": true, "resample": "automatic"])
        #expect(r["enlarger"]?["fit"] == "bicubicSharper", "\(r)")
        #expect(sc.s.active!.doc.size == PixelSize(width: 100, height: 50))
    }

    @Test func sixteenBitLayersKeepTheirDepthThroughTheProvider() throws {
        let sc = try scene(depth: 16)
        try sc.s.execute("image.imageSize", ["width": 80, "enlarger": true])
        #expect(sc.log.all.allSatisfy { $0.format.sample == .u16 })
        let p = rgba(sc.s, sc.a, 30, 20)
        #expect(abs(p.y - 0.25) < 1e-4 && p.x == 1, "\(p)")
    }

    // MARK: Falling back to the Resample alone

    /// What a fallback is compared on: the canvas, and every layer's pixels and mask in tree order (two
    /// sessions built alike differ in layer ids and smart object source ids).
    struct Pixels: Equatable {
        var size: PixelSize
        var surfaces: [Surface?]
        var masks: [Surface?]
        init(_ d: Document) {
            size = d.size; surfaces = []; masks = []
            func walk(_ ls: [Layer]) {
                for l in ls { surfaces.append(l.surface); masks.append(l.mask?.surface); walk(l.children ?? []) }
            }
            walk(d.layers)
        }
    }

    /// What a plain Image Size (no enlarger) makes, to compare a fallback with.
    func plain(_ params: JSONValue) throws -> Pixels {
        let sc = try scene(register: false)
        try sc.s.execute("image.imageSize", params)
        return Pixels(sc.s.active!.doc)
    }

    @Test func aTargetSmallerOnEitherAxisUsesTheResampleAlone() throws {
        for (w, h) in [(80, 10), (80, 20), (20, 40)] {
            let sc = try scene()
            let r = try sc.s.execute("image.imageSize", ["width": .int(w), "height": .int(h), "enlarger": true])
            #expect(sc.log.all.isEmpty, "\(w)×\(h)")
            #expect(r["enlarger"]?["used"] == false)
            #expect(r["enlarger"]?["reason"]?.stringValue?.contains("both axes") == true, "\(r)")
            #expect(Pixels(sc.s.active!.doc) == (try plain(["width": .int(w), "height": .int(h)])), "\(w)×\(h)")
        }
    }

    @Test func anEmptyEmptiedOrUnavailableSlotUsesTheResampleAlone() throws {
        let params: JSONValue = ["width": 100, "height": 50, "resample": "lanczos", "enlarger": true]
        let expected = try plain(params.setting("enlarger", false))

        // Never filled.
        let empty = try scene(register: false)
        let r = try empty.s.execute("image.imageSize", params)
        #expect(r["enlarger"]?["used"] == false)
        #expect(r["enlarger"]?["reason"]?.stringValue?.contains("register an ImageEnlarger") == true, "\(r)")
        #expect(Pixels(empty.s.active!.doc) == expected)

        // Filled, then emptied by the host (as PixelAgencyEditor's seams empty a slot whose model isn't ready), then
        // every slot emptied.
        for empty in [{ (r: ProviderRegistry) in r.unregister(.enlarge) }, { (r: ProviderRegistry) in r.removeAll() }] {
            let sc = try scene()
            empty(sc.s.intelligence.registry)
            #expect(!sc.s.intelligence.status(of: .enlarge).isAvailable && sc.s.intelligence.enlarger == nil)
            let r = try sc.s.execute("image.imageSize", params)
            #expect(r["enlarger"]?["used"] == false && sc.log.all.isEmpty)
            #expect(Pixels(sc.s.active!.doc) == expected)
        }

        // Filled with an enlarger that can't run here (no Metal device).
        let off = try scene { _ in ImageEnlargerClosure("Off", availability: { .unavailable(reason: "no Metal device") }) { s, _ in s } }
        let ro = try off.s.execute("image.imageSize", params)
        #expect(ro["enlarger"]?["reason"]?.stringValue?.contains("no Metal device") == true, "\(ro)")
        #expect(Pixels(off.s.active!.doc) == expected)
    }

    @Test func withoutTheFlagTheResultIsUnchanged() throws {
        let sc = try scene()
        let r = try sc.s.execute("image.imageSize", ["width": 80])
        #expect(r == ["width": 80, "height": 40])
        #expect(sc.log.all.isEmpty)
        // Resample off: the flag is ignored and says so.
        let none = try sc.s.execute("image.imageSize", ["resolution": 300, "resample": "none", "enlarger": true])
        #expect(none["enlarger"]?["used"] == false && sc.log.all.isEmpty)
    }

    @Test func aProviderReturningAnotherFormatFailsAndChangesNothing() throws {
        let sc = try scene { log in MarkingEnlarger(log: log, wrongFormat: true) }
        let past = sc.s.active!.history.pastCount
        #expect(throws: (any Error).self) { try sc.s.execute("image.imageSize", ["width": 80, "enlarger": true]) }
        #expect(sc.s.active!.doc.size == PixelSize(width: 40, height: 20) && sc.s.active!.history.pastCount == past)
    }

    // MARK: The job path

    /// The editor's path: `executeAsync` from the main actor, with a provider that needs the main actor (as one
    /// that touches AppKit or a MainActor-isolated cache would). The job runs off the main actor, so the hop
    /// completes; awaiting it doesn't block the main thread.
    @Test(.timeLimit(.minutes(1))) @MainActor func executeAsyncRunsTheChainAsABackgroundJob() async throws {
        let sc = try scene { log in MarkingEnlarger(log: log, delay: .milliseconds(5), hopsToMain: true) }
        let s = sc.s
        let past = s.active!.history.pastCount
        let r = try await s.executeAsync("image.imageSize", ["width": 100, "height": 50, "enlarger": true, "resample": "lanczos"])
        #expect(r["enlarger"]?["used"] == true && r["enlarger"]?["passes"] == 2, "\(r)")
        #expect(s.active!.doc.size == PixelSize(width: 100, height: 50))
        #expect(s.active!.history.pastCount == past + 1)
        #expect(s.runningJobs.isEmpty)
    }

    @Test func startRunsItInTheBackgroundLockedAndCancellable() throws {
        // Locked while it runs, then applied as one step.
        let sc = try scene { log in MarkingEnlarger(log: log, delay: .milliseconds(30)) }
        let s = sc.s
        let past = s.active!.history.pastCount
        guard case .job(let id) = try s.start("image.imageSize", ["width": 80, "enlarger": true]) else {
            Issue.record("expected a job"); return
        }
        #expect(s.activeJob?.label == "Image Size")
        #expect(throws: (any Error).self) { try s.execute("layer.new.layer") }
        let r = try s.waitJob(id)
        #expect(r["enlarger"]?["used"] == true && s.active!.doc.size == PixelSize(width: 80, height: 40))
        #expect(s.active!.history.pastCount == past + 1)

        // Cancelled: nothing changes.
        let slow = try scene { log in MarkingEnlarger(log: log, delay: .milliseconds(300)) }
        let t = slow.s
        let before = t.active!.history.pastCount
        guard case .job(let j) = try t.start("image.imageSize", ["width": 80, "enlarger": true]) else {
            Issue.record("expected a job"); return
        }
        #expect(t.cancelJob(j))
        #expect(throws: EngineError.cancelled) { try t.waitJob(j) }
        #expect(t.active!.doc.size == PixelSize(width: 40, height: 20) && t.active!.history.pastCount == before)
    }
}
