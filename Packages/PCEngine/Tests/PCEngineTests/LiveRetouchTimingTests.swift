// The receipt for AB-T-0299 item 2 (opt-in): what a live retouching stroke costs per push against rerunning the
// whole stroke, the way PixelAgencyEditor measured its scratch-copy previews (a 2000 × 1500 layer, a 60 px brush at
// hardness 50; Smudge's spacing about a pixel).
//
//     PCRAFT_LIVE_RETOUCH_BENCH=1 [PCRAFT_LIVE_RETOUCH_BENCH_REPORT=<file>] \
//         swift test -c release --filter PCEngineTests.LiveRetouchTimingTests

import Foundation
import PCDocument
@testable import PCEngine
import PCFoundation
import PCPaint
import Testing

@Suite struct LiveRetouchTimingTests {
    static let enabled = ProcessInfo.processInfo.environment["PCRAFT_LIVE_RETOUCH_BENCH"] == "1"

    func ms(_ body: () throws -> Void) rethrows -> Double {
        let start = ContinuousClock.now
        try body()
        let d = ContinuousClock.now - start
        return Double(d.components.seconds) * 1e3 + Double(d.components.attoseconds) / 1e15
    }

    /// The picture: a gradient with fine noise on a 2000 × 1500 layer.
    func picture() throws -> Session {
        let s = Session()
        try s.execute("file.new", ["width": 2000, "height": 1500, "background": "transparent"])
        try s.edit("Picture") { doc, a in
            doc.withRaster(of: a!) { sf in
                var data = [Float](repeating: 0, count: 2000 * 1500 * 4)
                for y in 0..<1500 {
                    for x in 0..<2000 {
                        let i = (y * 2000 + x) * 4
                        let n = Float((x &* 73_856_093 ^ y &* 19_349_663) & 1023) / 1023 * 0.1
                        data[i] = Float(x) / 2000 + n; data[i + 1] = Float(y) / 1500; data[i + 2] = 0.5 - n; data[i + 3] = 1
                    }
                }
                sf.writeRegion(PixelRect(x: 0, y: 0, width: 2000, height: 1500), data)
            }
        }
        return s
    }

    @Test(.enabled(if: LiveRetouchTimingTests.enabled))
    func pushAgainstRerun() throws {
        // Reruns on one session, the live stroke on another (a rerun's undo moves the revision an offer is for).
        let s = try picture(), ls = try picture()
        // A 600 px stroke, a point a pixel.
        let pts = (0...600).map { StrokePoint(700 + Double($0), 750 + 40 * sin(Double($0) / 90), 1) }
        func json(_ p: ArraySlice<StrokePoint>) -> JSONValue { .array(p.map { [.number($0.x), .number($0.y)] }) }
        let tools: [(String, JSONValue)] = [
            ("paint.smudge", ["size": 60, "hardness": 50, "strength": 50, "spacing": 1.7]),
            ("paint.cloneStamp", ["size": 60, "hardness": 50, "offset": [-300, 0]]),
            ("paint.blur", ["size": 60, "hardness": 50, "strength": 50, "radius": 4]),
        ]
        var report = "AB-T-0299 live retouching strokes, 2000 × 1500, 60 px brush at hardness 50 (release)\n"
        report += "tool: at 150 / 300 / 450 / 600 px — rerun of the whole stroke | one live push of the next 10 px; commit rerun | offering the live stroke + the commit taking it\n"
        for (cmd, base) in tools {
            var rerun: [String] = [], push: [String] = []
            var live = try LiveRetouchStroke.begin(ls, cmd, base.setting("points", json(pts[0..<2])))
            var at = 2
            for len in [150, 300, 450, 600] {
                while at + 10 <= len { try live.push(Array(pts[at..<(at + 10)])); at += 10 }
                let next = Array(pts[at..<min(at + 10, pts.count)])
                push.append(String(format: "%.2f", try ms { try live.push(next) }))
                at += next.count
                let p = base.setting("points", json(pts[0..<at]))
                rerun.append(String(format: "%.1f", try ms { try s.execute(cmd, p) }))
                #expect(s.undo())
            }
            while at < pts.count { try live.push(Array(pts[at..<min(at + 10, pts.count)])); at = min(at + 10, pts.count) }
            let p = base.setting("points", json(pts[...]))
            let commit = try ms { try s.execute(cmd, p) }
            #expect(s.undo())
            let offer = try ms { try LiveRetouchStroke.offer(ls, live) }
            var taken: JSONValue = .null
            let fromLive = try ms { taken = try ls.execute(cmd, p) }
            #expect(taken["fromLive"] == true)
            #expect(ls.undo())
            report += "\(cmd): \(rerun.joined(separator: " / ")) ms | \(push.joined(separator: " / ")) ms; commit \(String(format: "%.1f", commit)) ms | offer \(String(format: "%.1f", offer)) + \(String(format: "%.1f", fromLive)) ms\n"
        }
        print(report)
        if let path = ProcessInfo.processInfo.environment["PCRAFT_LIVE_RETOUCH_BENCH_REPORT"] {
            try report.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}
