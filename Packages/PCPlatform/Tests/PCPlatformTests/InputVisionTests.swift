// Pointer input: ports photocraft-tablet's appkit.rs tests onto the Swift state machine, plus real
// NSEvents built from CGEvents with tablet fields. Vision: geometry helpers on generated images.
// MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import AppKit
import CoreGraphics
import Foundation
import PCDocument
import PCFoundation
import Testing
@testable import PCPlatform

private func pen(_ type: UInt, _ p: Float, _ tilt: CGPoint = .zero, _ rot: Float = 0) -> RawTabletEvent {
    RawTabletEvent(type: type, subtype: 1, pressure: p, tilt: tilt, rotation: rot)
}

@Suite("Pointer input (NSEvent replaces photocraft-tablet)")
struct InputTests {
    @Test func tabletMouseEventsCarryPressureTiltRotation() {
        var st = TabletState()
        #expect(st.handle(pen(6, 0.5, CGPoint(x: 0.5, y: -0.25), 30)) == .set(PenSample(pressure: 0.5, tiltX: 30, tiltY: 15, rotation: 30)))
        guard case .set(let s?) = st.handle(pen(23, 0.8, CGPoint(x: -1, y: 1))) else { Issue.record("no sample"); return }
        #expect((s.pressure, s.tiltX, s.tiltY) == (0.8, -60, -60))
    }

    @Test func liftingThePenKeepsTheStrokesPressure() {
        var st = TabletState()
        _ = st.handle(pen(6, 0.7))
        for t: UInt in [2, 4, 26] { #expect(st.handle(pen(t, 0)) == .keep, "type \(t)") }
        guard case .set(let s?) = st.handle(pen(5, 0)) else { Issue.record("hover"); return }
        #expect(s.pressure == 0)
        #expect(st.handle(RawTabletEvent(type: 2, subtype: 0)) == .set(nil), "a mouse's button-up is a mouse")
    }

    @Test func mouseEventsAreFullPressureMiceAndOthersKeep() {
        var st = TabletState()
        for sub: Int16 in [0, 3, 99] { #expect(st.handle(RawTabletEvent(type: 1, subtype: sub, pressure: 1)) == .set(nil)) }
        for t: UInt in [0, 10, 22, 29, 34] { #expect(st.handle(RawTabletEvent(type: t)) == .keep) }
    }

    @Test func proximityTracksTheEraserEnd() {
        var st = TabletState()
        let prox = { (d: UInt, e: Bool) in RawTabletEvent(type: 24, device: d, entering: e) }
        guard case .set(let s?) = st.handle(prox(3, true)) else { Issue.record("eraser"); return }
        #expect(s.eraser && s.pressure == 0)
        guard case .set(let d?) = st.handle(pen(1, 0.4)) else { Issue.record("down"); return }
        #expect(d.eraser)
        #expect(st.handle(prox(3, false)) == .set(nil) && !st.eraser)
        #expect(st.handle(prox(2, true)) == .set(nil), "a puck is a mouse")
        guard case .set(let u?) = st.handle(prox(0, true)) else { Issue.record("unknown"); return }
        #expect(!u.eraser)
        guard case .set(let m?) = st.handle(RawTabletEvent(type: 5, subtype: 2, device: 3, entering: true)) else { Issue.record("subtype prox"); return }
        #expect(m.eraser)
    }

    @Test func malformedValuesAreClampedNotTrusted() {
        var st = TabletState()
        #expect(st.handle(pen(6, .nan, CGPoint(x: CGFloat.nan, y: .infinity), .nan)) == .set(PenSample(pressure: 1)))
        #expect(st.handle(pen(6, 4, CGPoint(x: 7, y: -9), -30)) == .set(PenSample(pressure: 1, tiltX: 60, tiltY: 60, rotation: 330)))
        #expect(PenSample(rotation: 725).sanitized().rotation == 5)
        #expect(PenSample(pressure: -0.5, rotation: -1e-9).sanitized().rotation == 0)
    }

    @MainActor @Test func realNSEventsFromCGEventsWithTabletFields() throws {
        func make(_ type: CGEventType, pressure: Double, tilt: (Double, Double), rotation: Double, subtype: Int64 = 1) throws -> NSEvent {
            let cg = try #require(CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: CGPoint(x: 100, y: 200), mouseButton: .left))
            cg.setIntegerValueField(.mouseEventSubtype, value: subtype)
            cg.setDoubleValueField(.mouseEventPressure, value: pressure)
            cg.setDoubleValueField(.tabletEventPointPressure, value: pressure)
            cg.setDoubleValueField(.tabletEventTiltX, value: tilt.0)
            cg.setDoubleValueField(.tabletEventTiltY, value: tilt.1)
            cg.setDoubleValueField(.tabletEventRotation, value: rotation)
            return try #require(NSEvent(cgEvent: cg))
        }
        var st = TabletState()
        let drag = try make(.leftMouseDragged, pressure: 0.6, tilt: (0.5, 0), rotation: 45)
        let ev = try #require(PointerInput.event(from: drag, state: &st) { CGPoint(x: $0.x * 2, y: $0.y * 2) })
        measure("CGEvent→NSEvent tablet drag: kind \(ev.kind) pressure \(ev.pressure) tilt \(ev.tilt) twist \(ev.twist) phase \(ev.phase)")
        #expect(ev.kind == .pen && ev.phase == .drag && ev.buttons == .primary)
        #expect(abs(ev.pressure - 0.6) < 0.01 && abs(ev.tilt.x - 30) < 0.5 && abs(ev.twist - 45) < 0.5)
        let mouse = try make(.leftMouseDown, pressure: 1, tilt: (0, 0), rotation: 0, subtype: 0)
        let m = try #require(PointerInput.event(from: mouse, state: &st))
        #expect(m.kind == .mouse && m.pressure == 1 && m.phase == .down)
    }

    @Test func coalescerBatchesDedupesAndKeepsLiftPressure() {
        var c = PointerCoalescer()
        c.push(PointerEvent(phase: .hover, posDoc: CGPoint(x: 0, y: 0), pressure: 0, kind: .pen))
        c.push(PointerEvent(phase: .hover, posDoc: CGPoint(x: 1, y: 0), pressure: 0, kind: .pen))
        c.push(PointerEvent(phase: .down, posDoc: CGPoint(x: 1, y: 0), pressure: 0.3, kind: .pen))
        c.push(PointerEvent(phase: .drag, posDoc: CGPoint(x: 5, y: 0), pressure: 0.6, kind: .pen))
        c.push(PointerEvent(phase: .drag, posDoc: CGPoint(x: 5, y: 0), pressure: 0.6, timeMicros: 9, kind: .pen))
        c.push(PointerEvent(phase: .drag, posDoc: CGPoint(x: 9, y: 0), pressure: 0.8, kind: .pen))
        c.push(PointerEvent(phase: .up, posDoc: CGPoint(x: 9, y: 0), pressure: 0, kind: .pen))
        let batch = c.drain()
        #expect(batch.map(\.phase) == [.hover, .down, .drag, .drag, .up])
        #expect(batch[0].posDoc.x == 1, "consecutive hovers collapse to the latest")
        #expect(batch[2].timeMicros == 9, "a repeated sample merges into the earlier one")
        #expect(batch.last!.pressure == 0.8, "the lift keeps the stroke's pressure")
        #expect(c.drain().isEmpty)
        let even = PointerCoalescer.resample(batch, spacing: 1)
        #expect(zip(even, even.dropFirst()).allSatisfy { hypot($1.posDoc.x - $0.posDoc.x, $1.posDoc.y - $0.posDoc.y) <= 1.0001 })
        #expect(even.count > batch.count)
    }
}

@Suite("Vision geometry helpers (fills photocraft gap G15)")
struct VisionTests {
    /// Sky over ground with a horizon through the centre rising by `degrees` to the right.
    func horizonImage(degrees: Double, w: Int = 640, h: Int = 480) -> RasterBuffer {
        var v = [Float](repeating: 0, count: w * h * 3)
        let slope = tan(degrees * .pi / 180)
        for y in 0..<h { for x in 0..<w {
            let horizonY = Double(h) / 2 - (Double(x) - Double(w) / 2) * slope
            let sky = Double(y) < horizonY
            let c: SIMD3<Float> = sky ? SIMD3(0.45, 0.65, 0.95) * (1 - Float(y) / Float(h) * 0.3) : SIMD3(0.35, 0.28, 0.18) + Float((x * 7 + y * 13) % 17) / 400
            for k in 0..<3 { v[(y * w + x) * 3 + k] = c[k] }
        } }
        return RasterBuffer(width: w, height: h, format: PixelFormat(mode: .rgb, sample: .u8, alpha: false), floats: v)
    }

    @Test func horizonAndStraighten() throws {
        let img = horizonImage(degrees: 6)
        let h = try VisionGeometry.horizon(img)
        measure("Vision horizon on a synthetic 6° horizon: \(h.map { "\($0.angleDegrees)°" } ?? "none")")
        if let h { #expect(abs(h.angleDegrees - 6) < 1.5, "\(h.angleDegrees)") }
        let level = try VisionGeometry.straighten(img, degrees: -6)
        #expect(level.width < img.width && level.height < img.height && abs(Double(level.width) / Double(level.height) - 4.0 / 3.0) < 0.02)
    }

    @Test func rectanglesAndPerspectiveCrop() throws {
        let w = 640, h = 480
        // A light quadrilateral (a slightly skewed card) on a dark background.
        let corners = [CGPoint(x: 160, y: 120), CGPoint(x: 500, y: 140), CGPoint(x: 480, y: 380), CGPoint(x: 140, y: 360)]
        let path = CGMutablePath(); path.addLines(between: corners); path.closeSubpath()
        let cov = VectorRasterizer.coverage(path, rect: PixelRect(x: 0, y: 0, width: w, height: h))
        let img = RasterBuffer(width: w, height: h, format: PixelFormat(mode: .rgb, sample: .u8, alpha: false),
                               floats: cov.flatMap { c in [0.1 + 0.85 * c, 0.1 + 0.85 * c, 0.12 + 0.8 * c] })
        let quads = try VisionGeometry.rectangles(img)
        let q = try #require(quads.first)
        let err = zip(q.corners, corners).map { hypot($0.x - $1.x, $0.y - $1.y) }.max()!
        measure("Vision rectangle detection: \(quads.count) quad(s), worst corner error \(err) px, confidence \(q.confidence)")
        #expect(err < 6, "corners in image pixels, y down")
        let flat = try VisionGeometry.perspectiveCorrect(img, quad: q)
        measure("perspective crop output \(flat.width)×\(flat.height)")
        #expect(flat.width > 300 && flat.height > 200)
        let centre = flat.floats()[((flat.height / 2) * flat.width + flat.width / 2) * 3]
        #expect(centre > 0.8, "the card fills the corrected image")
        if let doc = try VisionGeometry.document(img) { measure("document segmentation corners \(doc.corners)") }
    }

    @Test func textRecognition() throws {
        var s = CharStyle(fontFamily: "Helvetica Neue", sizePt: 64); s.weight = 700
        var block = TextLayer(text: "PHOTOCRAFT NATIVE")
        block.runs = [TextRun(len: block.text.utf8.count, style: s)]
        block.transform = .translate(40, 120)
        let r = TextEngine.rasterizeCoverage(block, sample: .u8)
        let w = 900, h = 220
        var v = [Float](repeating: 1, count: w * h)
        for y in r.rect.y0..<r.rect.y1 { for x in r.rect.x0..<r.rect.x1 where x >= 0 && y >= 0 && Int(x) < w && Int(y) < h {
            v[Int(y) * w + Int(x)] = 1 - r.surface.pixel(x: x, y: y)[0]
        } }
        let img = RasterBuffer(width: w, height: h, format: .gray8, floats: v)
        let lines = try VisionGeometry.recognizeText(img)
        measure("Vision OCR of CoreText-rendered text: \(lines.map { "\($0.string) (\($0.confidence))" })")
        let joined = lines.map(\.string).joined(separator: " ").uppercased()
        #expect(joined.contains("PHOTOCRAFT") && joined.contains("NATIVE"))
        if let first = lines.first { #expect(first.quad.topLeft.y < first.quad.bottomLeft.y, "y down") }
    }

    @Test func saliencyPointsAtTheSubject() throws {
        let w = 400, h = 300
        var v = [Float](repeating: 0, count: w * h * 3)
        for y in 0..<h { for x in 0..<w {
            let d = hypot(Double(x - 300), Double(y - 80))
            let c: SIMD3<Float> = d < 45 ? SIMD3(0.95, 0.1, 0.1) : SIMD3(0.5, 0.52, 0.5) + Float((x * 3 + y * 5) % 11) / 300
            for k in 0..<3 { v[(y * w + x) * 3 + k] = c[k] }
        } }
        let img = RasterBuffer(width: w, height: h, format: PixelFormat(mode: .rgb, sample: .u8, alpha: false), floats: v)
        for kind in [SaliencyKind.attention, .objectness] {
            let s = try VisionGeometry.saliency(img, kind: kind)
            let hm = s.heatMap.data
            let peak = hm.indices.max { hm[$0] < hm[$1] }!
            let px = peak % w, py = peak / w
            measure("saliency \(kind): peak at (\(px), \(py)) (subject at 300, 80), regions \(s.regions)")
            #expect(hypot(Double(px - 300), Double(py - 80)) < 90, "\(kind) heat map peak near the subject (y down)")
        }
        let crop = try VisionGeometry.cropSuggestion(img, aspect: 1)
        #expect(crop.width == 300 && crop.contains(CGPoint(x: 300, y: 80)))
    }
}
