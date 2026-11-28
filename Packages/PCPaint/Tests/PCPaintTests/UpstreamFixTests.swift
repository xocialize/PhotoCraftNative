// Fixes taken from photocraft after PhotoCraftNative's base (184c226a), 2026-11-27: brush smoothing as measured in the
// reference application (#11888, #12246, #7747), stroke step caps (#8957, #11195) and procedural tip budgets (#8957).
// MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import Testing
import PCFoundation
@testable import PCPaint

@Suite struct UpstreamSmoothingTests {
    @Test func pullFollowsTheMeasuredTimeConstant() {
        #expect(smoothingPull(0) == 1 && smoothingPull(.nan) == 1, "no smoothing")
        // tau 43 ms at 10 %, 173 ms at 50 %, 314 ms at 100 %
        #expect(abs(smoothingPull(0.1) - (1 - exp(-16.0 / 43.0))) < 0.01)
        #expect(abs(smoothingPull(0.5) - (1 - exp(-16.0 / 173.0))) < 0.005)
        #expect(abs(smoothingPull(1) - (1 - exp(-16.0 / 314.0))) < 1e-9)
    }

    /// The reference's lag: a 200 px drag in 40 moves 10 ms apart ends 19 px short at 10 % and 78 px short at 50 %.
    @Test func aDragLagsAsTheReferenceDoes() {
        func shortfall(_ amount: Float) -> Double {
            var s = Smoother(Smoothing(amount: amount, catchUp: true, catchUpOnEnd: false), zoom: 1)
            var out: [StrokePoint] = []
            for i in 0...40 { s.push(StrokePoint(Double(i) * 5, 0, 1).with(time: Double(i) * 10), &out) }
            return 200 - out.last!.x
        }
        #expect(abs(shortfall(0.1) - 19) < 3, "\(shortfall(0.1))")
        #expect(abs(shortfall(0.5) - 78) < 6, "\(shortfall(0.5))")
    }

    @Test func aTimedStrokeStaysPutOnAZeroTimeReport() {
        var s = Smoother(Smoothing(amount: 0.5, catchUp: true, catchUpOnEnd: false), zoom: 1)
        var out: [StrokePoint] = []
        s.push(StrokePoint(0, 0, 1).with(time: 0), &out)
        s.push(StrokePoint(50, 0, 1).with(time: 10), &out)
        let at = out.last!.x
        s.push(StrokePoint(60, 0, 1).with(time: 10), &out) // same millisecond
        #expect(out.last!.x == at, "no time passed: the brush stays")
    }

    @Test func pulledStringDoesNotCatchUpAtTheEnd() {
        var s = Smoother(Smoothing(amount: 0.5, pulledString: true, catchUpOnEnd: true), zoom: 1)
        var out: [StrokePoint] = []
        s.push(StrokePoint(0, 0, 1), &out)
        s.push(StrokePoint(400, 0, 1), &out)
        s.finish(&out)
        #expect(abs(out.last!.x - 250) < 1e-6, "the brush stays 150 px behind: \(out.last!.x)")
    }

    @Test func aPenChangingPressureInPlaceStillCatchesUp() {
        var s = Smoother(Smoothing(amount: 0.5, catchUp: true, catchUpOnEnd: true), zoom: 1)
        var out: [StrokePoint] = []
        s.push(StrokePoint(0, 0, 0.2), &out)
        s.push(StrokePoint(0, 0, 0.9), &out)
        out.removeAll()
        s.finish(&out)
        // the position matches; the pose doesn't, so the end catches up to the last pressure
        #expect(out.last.map { abs($0.pressure - 0.9) < 1e-6 } ?? true)
    }
}

@Suite struct UpstreamStepCapTests {
    @Test func aStrokeOfFarSegmentsStopsAtTheTotalCap() {
        var steps: UInt64 = 0
        var w = PathWalker(buildUpIntervalMs: nil)
        w.push(StrokePoint(0, 0, 1), stepLen: { _ in 0.25 }) { _ in steps += 1 }
        for i in 1...8 { w.push(StrokePoint(1e9 * Double(i), 0, 1), stepLen: { _ in 0.25 }) { _ in steps += 1 } }
        #expect(steps <= maxStepsPerStroke, "\(steps)")
    }

    @Test func oneFarSegmentStopsAtTheSegmentCap() {
        var steps = 0
        var w = PathWalker(buildUpIntervalMs: nil)
        w.push(StrokePoint(0, 0, 1), stepLen: { _ in 0.25 }) { _ in steps += 1 }
        w.push(StrokePoint(1e12, 0, 1), stepLen: { _ in 0.25 }) { _ in steps += 1 }
        #expect(steps <= maxDistanceStepsPerSegment + 1, "\(steps)")
    }

    @Test func speedSpacingOverAbsurdTimestampsStops() {
        var steps: UInt64 = 0
        var w = PathWalker(buildUpIntervalMs: nil).speedSpacing(1)
        w.push(StrokePoint(0, 0, 1), stepLen: { _ in 1 }) { _ in steps += 1 }
        w.push(StrokePoint(1e9, 0, 1).with(time: 1e12), stepLen: { _ in 1 }) { _ in steps += 1 }
        #expect(steps <= maxStepsPerStroke, "\(steps)")
    }

    @Test func tipsWithAbsurdPrimitiveCountsStayCheap() {
        let t0 = Date()
        _ = Procedural.spatterTip(256, 1, .max)
        _ = Procedural.grassTip(256, 1, .max)
        _ = Procedural.rakeTip(256, 1, .max)
        #expect(Procedural.clampPrimitives(256, .max) <= Procedural.maxPrimitives)
        #expect(Procedural.clampPrimitives(4096, .max) == UInt32(Procedural.maxTipWork / (4096 * 4096)))
        #expect(Date().timeIntervalSince(t0) < 60)
    }
}

@Suite struct UpstreamBoundTests {
    /// photocraft #11070 `a_dab_stroke_between_distant_points_is_refused_before_reading`: two distant points would
    /// read gigabytes of working copy; nothing is painted and nothing is read.
    @Test(.timeLimit(.minutes(1))) func aDabStrokeBetweenDistantPointsIsRefusedBeforeReading() {
        #expect(Retouch.dabStrokeFits(PixelRect(x0: 0, y0: 0, x1: 4000, y1: 4000), halo: 8, channels: 4))
        #expect(!Retouch.dabStrokeFits(PixelRect(x0: 0, y0: 0, x1: 200_000, y1: 200_000), halo: 8, channels: 4))
        #expect(!Retouch.dabStrokeFits(PixelRect(x0: .min, y0: .min, x1: .max, y1: .max), halo: 100, channels: 4))
        var surface = Surface(format: .rgba8)
        surface.fill(PixelRect(x0: 0, y0: 0, x1: 8, y1: 8), with: [1, 0, 0, 1])
        let before = surface
        var brush = BrushSettings()
        brush.size = 10
        let stroke = Stroke(brush: brush, points: [StrokePoint(x: 4, y: 4), StrokePoint(x: 900_000_000, y: 900_000_000)])
        var calls = 0
        let damage = Retouch.applyDabStroke(&surface, stroke, selection: nil, lockTransparency: false, halo: 2) { _, _ in calls += 1 }
        #expect(damage.isEmpty && calls == 0 && surface == before)
    }

    /// photocraft #8772: a stored tile's width × height is checked before it is used as a length.
    @Test func aTileWhoseExtentsOverflowIsRefused() {
        let json = Data(#"{"width": 4294967295, "height": 4294967295, "data": ""}"#.utf8)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(GrayTile.self, from: json) }
    }
}
