// Port of photocraft-paint (crates/paint/src/render.rs; engine retouch_cmds.rs clone/heal sequence), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// The canvas-facing stroke (PointerEvents → damage → one transaction) and the clone/heal/history
// sampling sequence.

import Foundation
import Testing
import PCFoundation
@testable import PCPaint

func events(_ pts: [(Double, Double)], pen: Bool = true) -> [PointerEvent] {
    pts.enumerated().map { i, p in
        PointerEvent(position: PaintPoint(p.0, p.1), pressure: 0.5 + 0.5 * Float(i % 3) / 2, tilt: SIMD2(Float(i % 4) * 10, -15), twist: Float(i) * 7,
                     timeUs: 1_000_000 + UInt64(i) * 8_000, kind: pen ? .pen : .mouse)
    }
}

@Suite(.serialized) struct SessionTests {
    let path: [(Double, Double)] = (0..<30).map { (20 + Double($0) * 6, 50 + 20 * sin(Double($0) / 4)) }

    func run(_ b: BrushSettings, backend: PaintBackend, layer: Surface, symmetry: PresetSymmetry? = nil) throws -> (PaintStroke, StrokeTransaction, PixelRect) {
        let s = try PaintStroke(brush: b, layer: layer, symmetry: symmetry, backend: backend)
        var dmg = PixelRect.empty
        let ev = events(path)
        var i = 0
        while i < ev.count {
            let u = try s.feed(Array(ev[i..<min(i + 4, ev.count)]))
            dmg = dmg.union(u.damage)
            #expect(Set(u.tiles) == Set(u.damage.tiles))
            i += 4
        }
        let t = try s.end()
        return (s, t, dmg)
    }

    @Test func pointerEventsBecomeStrokePoints() {
        let e = PointerEvent(position: PaintPoint(3, 4), pressure: 0.3, tilt: SIMD2(10, -20), twist: 45, timeUs: 2_500, kind: .pen)
        let p = e.strokePoint(originUs: 500)
        #expect(p.x == 3 && p.y == 4 && p.pressure == 0.3 && p.tiltX == 10 && p.tiltY == -20 && p.rotation == 45 && p.time == 2)
        let m = PointerEvent(position: PaintPoint(3, 4), pressure: 0.3, tilt: SIMD2(10, -20), kind: .mouse).strokePoint(originUs: 0)
        #expect(m.pressure == 1 && m.tiltX == 0 && m.rotation == 0)
    }

    @Test func cpuAndMetalSessionsCommitIdenticalPixelsAndTransactions() throws {
        let b = with(brush()) {
            $0.size = 16; $0.hardness = 0.4; $0.opacity = 0.8; $0.flow = 0.5
            $0.shapeDynamics = ShapeDynamics(enabled: true, size: .controlled(.penPressure), angle: .jitter(0.4))
            $0.smoothing = Smoothing(amount: 0.5)
        }
        var layer = Surface(format: .rgba8)
        layer.fill(PixelRect(x0: 0, y0: 0, x1: 300, y1: 100), with: [0.9, 0.8, 0.7, 1])
        let (cs, ct, _) = try run(b, backend: .cpu, layer: layer)
        #expect(!cs.usesMetal)
        var oneShot = layer
        let pts = events(path).map { $0.strokePoint(originUs: 1_000_000) }
        renderStroke(&oneShot, b, pts)
        let area = PixelRect(x0: -10, y0: -10, x1: 320, y1: 120)
        #expect(cs.surface.readRegion(area) == oneShot.readRegion(area), "the session commits what the one-shot render paints")
        guard MetalContext.shared != nil else { return }
        let (gs, gt, _) = try run(b, backend: .metal, layer: layer)
        #expect(gs.usesMetal)
        #expect(gs.surface.readRegion(area) == cs.surface.readRegion(area))
        #expect(gt.bounds == ct.bounds)
        // Undo restores the layer; redo restores the stroke.
        var l = gs.surface
        gt.undo(&l)
        #expect(l.readRegion(area) == layer.readRegion(area))
        gt.redo(&l)
        #expect(l.readRegion(area) == gs.surface.readRegion(area))
        #expect(!gt.after.isEmpty && gt.before.count == gt.after.count)
    }

    @Test func liveFramesMatchFinishingTheStrokeAtThatPoint() throws {
        let b = with(brush()) { $0.size = 12; $0.smoothing = Smoothing(amount: 0.6); $0.opacity = 0.7 }
        let layer = Surface(format: .rgba16)
        for backend in [PaintBackend.cpu, .metal] {
            if backend == .metal && MetalContext.shared == nil { continue }
            let s = try PaintStroke(brush: b, layer: layer, backend: backend)
            let ev = events(path)
            var i = 0
            while i < ev.count {
                try s.feed(Array(ev[i..<min(i + 5, ev.count)]))
                var expected = layer
                renderStroke(&expected, b, ev[0..<min(i + 5, ev.count)].map { $0.strokePoint(originUs: 1_000_000) })
                let area = PixelRect(x0: -10, y0: -10, x1: 320, y1: 120)
                #expect(s.surface.readRegion(area) == expected.readRegion(area), "\(backend) after \(i + 5) events")
                i += 5
            }
        }
    }

    @Test func airbrushTicksWhileThePointerIsHeld() throws {
        let b = with(brush()) { $0.size = 20; $0.flow = 0.05; $0.buildUp = true; $0.buildUpRate = 50 }
        let s = try PaintStroke(brush: b, layer: Surface(format: .rgba8), backend: .auto)
        try s.feed([PointerEvent(position: PaintPoint(50, 50), timeUs: 0)])
        #expect(s.wantsTime)
        let a0 = s.surface.rgba(50, 50).w
        _ = try s.tick(timeUs: 500_000)
        let a1 = s.surface.rgba(50, 50).w
        #expect(a1 > a0, "\(a0) → \(a1)")
        _ = try s.end()
    }

    @Test func symmetrySessionsMergePassesUnderOneCeiling() throws {
        let b = with(brush()) { $0.size = 14; $0.opacity = 0.5 }
        let sym = PresetSymmetry(.vertical, center: SIMD2(100, 50), rotation: 0)!
        let (s, t, _) = try run(b, backend: .cpu, layer: Surface(format: .rgba32f), symmetry: sym)
        #expect(!s.usesMetal)
        // Mirrored about x = 100: both halves painted, and where they overlap the opacity stays capped.
        #expect(s.surface.rgba(20, 50).w > 0.45 && s.surface.rgba(180, 50).w > 0.45)
        for x: Int32 in 0..<200 { #expect(s.surface.rgba(x, 50).w <= 0.5 + 1e-5) }
        #expect(t.bounds.contains(PixelRect(x0: 20, y0: 45, x1: 180, y1: 55)))
        guard MetalContext.shared != nil else { return }
        let (g, gt, _) = try run(b, backend: .metal, layer: Surface(format: .rgba32f), symmetry: sym)
        #expect(g.usesMetal)
        let area = PixelRect(x0: -10, y0: -10, x1: 220, y1: 120)
        #expect(g.surface.readRegion(area) == s.surface.readRegion(area))
        #expect(gt.bounds == t.bounds)
    }
}

@Suite struct CloneTests {
    func layer() -> Surface {
        var s = Surface(format: .rgba32f)
        s.fill(PixelRect(x0: 0, y0: 0, x1: 200, y1: 100), with: [0.2, 0.2, 0.2, 1])
        s.fill(PixelRect(x0: 100, y0: 0, x1: 120, y1: 100), with: [1, 0, 0, 1])
        return s
    }

    @Test func cloneStampCopiesFromTheOffsetWithoutRecloning() {
        var s = layer()
        let st = toolStroke([(30, 50), (70, 50)], 12, 1)
        // Destination + 80 = source: x 30…70 clones x 110…150 (red at 100…120).
        let d = Retouch.cloneStamp(&s, st, source: layer(), map: .offset(80, 0))
        #expect(!d.isEmpty)
        #expect(s.rgba(30, 50).x > 0.99 && s.rgba(30, 50).y < 0.01, "red cloned to x 30")
        #expect(abs(s.rgba(60, 50).x - 0.2) < 1e-4, "grey from x 140")
        // A far source fails cleanly instead of reading a truncated window.
        var t = layer()
        #expect(Retouch.cloneStamp(&t, st, source: layer(), map: .offset(Double(Int32.max), 0)).isEmpty)
    }

    @Test func transformedMappingsResampleAndAlignedSourcesKeepTheirAnchor() {
        let m = CloneMapping.transformMatrix(scale: SIMD2(200, 200), rotation: 0, flipH: false, flipV: false)
        #expect(abs(m.x - 0.5) < 1e-12 && abs(m.w - 0.5) < 1e-12)
        let flip = CloneMapping(source: SIMD2(110, 50), anchor: SIMD2(30, 50), m: CloneMapping.transformMatrix(scale: SIMD2(100, 100), rotation: 0, flipH: true, flipV: false))
        #expect(!flip.isTranslation)
        let p = flip.map(40, 50)
        #expect(abs(p.x - 100) < 1e-9 && abs(p.y - 50) < 1e-9)
        let r = Retouch.cloneSample(layer(), rect: PixelRect(x0: 20, y0: 40, x1: 40, y1: 60), map: flip)!
        #expect(r.rect == PixelRect(x0: 20, y0: 40, x1: 40, y1: 60))
        var src = CloneSource(source: SIMD2(150, 50), aligned: true)
        let a = src.mapping(firstPoint: SIMD2(10, 10))
        let b = src.mapping(firstPoint: SIMD2(60, 70))
        #expect(a.anchor == b.anchor && b.anchor == SIMD2(10, 10), "aligned keeps the first pairing")
        #expect(src.samplePoint(for: SIMD2(20, 10)) == SIMD2(160, 50))
        var na = CloneSource(source: SIMD2(150, 50), aligned: false)
        _ = na.mapping(firstPoint: SIMD2(10, 10))
        #expect(na.mapping(firstPoint: SIMD2(60, 70)).anchor == SIMD2(60, 70))
    }

    @Test func healingInjectsTheSolverOverThePaddedMask() {
        var s = layer()
        var calls = 0
        let d = Retouch.healingBrush(&s, toolStroke([(40, 50)], 10, 1), source: layer(), map: .offset(70, 0)) { w, h, ch, src, dst, mask in
            calls += 1
            #expect(src.count == w * h * ch && dst.count == src.count && mask.count == w * h)
            // A plain copy "solve": the source where masked.
            return (0..<(w * h * ch)).map { mask[$0 / ch] ? src[$0] : dst[$0] }
        }
        #expect(calls == 1 && !d.isEmpty)
        #expect(s.rgba(40, 50).x > 0.99, "the red source healed in")
        #expect(abs(s.rgba(40, 70).x - 0.2) < 1e-4, "outside the stroke untouched")
    }

    @Test func historyBrushAndLiveRetouchMatchTheOneShotCommit() {
        let original = layer()
        var current = original
        current.fill(PixelRect(x0: 0, y0: 0, x1: 200, y1: 100), with: [0, 0, 1, 1])
        var st = toolStroke([(20, 50), (90, 52), (150, 45)], 14, 0.5)
        st.brush.smoothing = Smoothing(amount: 0.5)
        var oneShot = current
        Retouch.historyBrush(&oneShot, st, history: original)
        #expect(abs(oneShot.rgba(90, 51).z - 0.2) < 0.02, "history painted back")
        var live = LiveRetouch(brush: st.brush, layer: current, paint: .history(original))
        var i = 0
        while i < st.points.count {
            _ = live.push(Array(st.points[i..<min(i + 1, st.points.count)]))
            i += 1
        }
        let area = PixelRect(x0: 0, y0: 0, x1: 200, y1: 100)
        #expect(live.surface.readRegion(area) == oneShot.readRegion(area), "live preview (with its tail) equals the commit")
        var cloneLive = LiveRetouch(brush: st.brush, layer: current, paint: .clone(source: original, map: .offset(10, 0)))
        _ = cloneLive.push(st.points)
        var cloneOne = current
        Retouch.cloneStamp(&cloneOne, st, source: original, map: .offset(10, 0))
        #expect(cloneLive.surface.readRegion(area) == cloneOne.readRegion(area))
    }

    @Test func metalOneShotRenderEqualsTheCPUReference() throws {
        guard MetalContext.shared != nil else { return }
        for p in BrushPresets.builtin() {
            var a = Surface(format: .rgba8), g = Surface(format: .rgba8)
            let pts = (0..<20).map { StrokePoint(40 + Double($0) * 8, 60, 0.8).with(time: Double($0) * 16) }
            let da = renderStroke(&a, p.brush, pts)
            let dg = try renderStrokeMetal(&g, p.brush, pts)
            #expect(da == dg, "\(p.name)")
            #expect(a.readInterleaved(da) == g.readInterleaved(da), "\(p.name)")
        }
    }
}
