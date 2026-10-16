// Live strokes for the retouching commands (AB-T-0299 item 2): `LiveRetouchStroke`, pushed a few points at a time,
// shows what the command commits, and offered to the command it is what the command commits (AB-L-0280).

import Foundation
import PCDocument
@testable import PCEngine
import PCFoundation
import PCPaint
import Testing

@Suite struct LiveRetouchTests {
    static let (w, h) = (96, 72)

    /// A colour gradient with fine noise and a hard-edged dark square, at `depth`; with `two`, a half-transparent
    /// layer of stripes above it (the active layer).
    func session(_ depth: Int, two: Bool = false, smoothing: Float = 0) throws -> Session {
        let s = Session()
        try s.execute("file.new", ["width": .int(Self.w), "height": .int(Self.h), "depth": .int(depth), "background": "transparent"])
        s.tools.brush.smoothing = Smoothing(amount: smoothing)
        try s.edit("Picture") { doc, a in
            doc.withRaster(of: a!) { sf in
                let fmt = sf.format
                var data: [Float] = []
                for y in 0..<Int32(Self.h) {
                    for x in 0..<Int32(Self.w) {
                        let n = Float(UInt32(bitPattern: (x &* 73_856_093) ^ (y &* 19_349_663)) % 1000) / 1000 * 0.1 - 0.05
                        let dark = (40..<56).contains(x) && (28..<44).contains(y)
                        let c = dark ? SIMD4<Float>(0.1, 0.05, 0.3, 1) : SIMD4(0.3 + 0.006 * Float(x) + n, 0.6 - 0.004 * Float(y) + n, 0.45 + n, 1)
                        data += fromRGBA(fmt, c)
                    }
                }
                sf.writeRegion(PixelRect(x: 0, y: 0, width: Self.w, height: Self.h), data)
            }
        }
        if two {
            try s.execute("layer.new.layer")
            try s.edit("Stripes") { doc, a in
                doc.withRaster(of: a!) { sf in
                    for x in stride(from: 0, to: Self.w, by: 6) { sf.fill(PixelRect(x: x, y: 0, width: 2, height: Self.h), with: fromRGBA(sf.format, SIMD4(1, 0.9, 0.2, 0.5))) }
                }
            }
        }
        return s
    }

    func layer(_ s: Session) -> [Float] {
        s.active!.doc.layer(s.active!.activeLayer!)!.rasterSurface!.readRegion(PixelRect(x: 0, y: 0, width: Self.w, height: Self.h))
    }

    func layer(_ d: Document, _ id: LayerId) -> [Float] {
        d.layer(id)!.rasterSurface!.readRegion(PixelRect(x: 0, y: 0, width: Self.w, height: Self.h))
    }

    /// A wavy stroke across the square.
    static let points: [StrokePoint] = (0..<14).map { i in StrokePoint(14 + 5.2 * Double(i), 30 + 9 * sin(Double(i) / 2.3), 1) }

    static func json(_ pts: [StrokePoint]) -> JSONValue { .array(pts.map { [.number($0.x), .number($0.y)] }) }

    /// Each command's params besides the points.
    static let params: [String: JSONValue] = [
        "paint.smudge": ["size": 18, "hardness": 60, "strength": 70, "spacing": 8],
        "paint.blur": ["size": 20, "hardness": 50, "strength": 100, "radius": 2.5],
        "paint.sharpen": ["size": 16, "strength": 80],
        "paint.sponge": ["size": 22, "mode": "saturate", "flow": 60],
        "paint.cloneStamp": ["size": 14, "hardness": 80, "opacity": 90, "offset": [12, 9]],
    ]

    func params(_ cmd: String, _ pts: [StrokePoint], _ extra: JSONValue = [:]) -> JSONValue {
        var p = Self.params[cmd]!.setting("points", Self.json(pts))
        for (k, v) in extra.objectValue ?? [:] { p = p.setting(k, v) }
        return p
    }

    /// The live stroke, begun with the first two points and pushed three at a time, shows what the command commits;
    /// offered to the command, the command takes it. Undo goes back to before the stroke.
    @Test(arguments: ["paint.smudge", "paint.blur", "paint.sharpen", "paint.sponge", "paint.cloneStamp"])
    func liveEqualsCommitAndIsTaken(_ cmd: String) throws {
        for depth in [8, 16, 32] {
            let p = params(cmd, Self.points)
            let oneShot = try session(depth)
            try oneShot.execute(cmd, p)
            let want = layer(oneShot)

            let s = try session(depth)
            let before = layer(s)
            let id = s.active!.activeLayer!
            var live = try LiveRetouchStroke.begin(s, cmd, params(cmd, Array(Self.points.prefix(2))))
            for chunk in stride(from: 2, to: Self.points.count, by: 3) {
                try live.push(Array(Self.points[chunk..<min(chunk + 3, Self.points.count)]))
            }
            #expect(layer(live.doc, id) == want, "\(cmd) at \(depth) bits: the live stroke shows what the command commits")
            #expect(layer(s) == before, "\(cmd): the session's document is untouched until the commit")
            try LiveRetouchStroke.offer(s, live)
            let r = try s.execute(cmd, p)
            #expect(r["fromLive"] == true, "\(cmd): the commit takes the live stroke: \(r)")
            #expect(layer(s) == want)
            #expect(s.undo() && layer(s) == before)
        }
    }

    /// A click (one point) shows its dab before the stroke ends; with Smoothing, the catch-up the commit adds shows
    /// while drawing and is taken back as the stroke goes on.
    @Test(arguments: ["paint.smudge", "paint.blur", "paint.cloneStamp"])
    func theEndOfTheStrokeShowsAsTheCommitDrawsIt(_ cmd: String) throws {
        let click = [StrokePoint(48, 36, 1)]
        let one = try session(8)
        try one.execute(cmd, params(cmd, click))
        let s = try session(8)
        let id = s.active!.activeLayer!
        let live = try LiveRetouchStroke.begin(s, cmd, params(cmd, click))
        #expect(layer(live.doc, id) == layer(one), "\(cmd): a click")

        let smooth = try session(8, smoothing: 0.6)
        try smooth.execute(cmd, params(cmd, Self.points))
        let s2 = try session(8, smoothing: 0.6)
        var live2 = try LiveRetouchStroke.begin(s2, cmd, params(cmd, Array(Self.points.prefix(1))))
        for pt in Self.points.dropFirst() { try live2.push([pt]) }
        #expect(layer(live2.doc, s2.active!.activeLayer!) == layer(smooth), "\(cmd): with Smoothing's catch-up")
    }

    /// Sample All Layers: Blur and Smudge work on what the document shows and lay it onto the layer.
    @Test(arguments: ["paint.smudge", "paint.blur"])
    func sampleAllLayers(_ cmd: String) throws {
        let p = params(cmd, Self.points, ["sampleAllLayers": true])
        let one = try session(16, two: true)
        try one.execute(cmd, p)
        let s = try session(16, two: true)
        let id = s.active!.activeLayer!
        var live = try LiveRetouchStroke.begin(s, cmd, params(cmd, Array(Self.points.prefix(3)), ["sampleAllLayers": true]))
        try live.push(Array(Self.points.dropFirst(3)))
        #expect(layer(live.doc, id) == layer(one))
        // Clone Stamp sampling all layers composites the document when the stroke starts.
        let cp = params("paint.cloneStamp", Self.points, ["sampleLayer": "all"])
        let c1 = try session(16, two: true)
        try c1.execute("paint.cloneStamp", cp)
        let c2 = try session(16, two: true)
        var lc = try LiveRetouchStroke.begin(c2, "paint.cloneStamp", params("paint.cloneStamp", Array(Self.points.prefix(3)), ["sampleLayer": "all"]))
        try lc.push(Array(Self.points.dropFirst(3)))
        #expect(layer(lc.doc, c2.active!.activeLayer!) == layer(c1))
    }

    /// An offer for other params, points or a document that has changed isn't taken, and is withdrawn.
    @Test func aMismatchedOfferIsNotTaken() throws {
        let s = try session(8)
        let live = try LiveRetouchStroke.begin(s, "paint.smudge", params("paint.smudge", Self.points))
        try LiveRetouchStroke.offer(s, live)
        let r = try s.execute("paint.smudge", params("paint.smudge", Self.points, ["strength": 20]))
        #expect(r["fromLive"] == nil)
        #expect(s.state[LiveRetouchStroke.CommitKey.self] == nil, "withdrawn")
        // The document changed since: not taken.
        let live2 = try LiveRetouchStroke.begin(s, "paint.blur", params("paint.blur", Self.points))
        try s.execute("paint.sponge", params("paint.sponge", Self.points))
        try LiveRetouchStroke.offer(s, live2)
        #expect(try s.execute("paint.blur", params("paint.blur", Self.points))["fromLive"] == nil)
        // Fewer points: not taken.
        let live3 = try LiveRetouchStroke.begin(s, "paint.blur", params("paint.blur", Self.points))
        try LiveRetouchStroke.offer(s, live3)
        #expect(try s.execute("paint.blur", params("paint.blur", Array(Self.points.prefix(5))))["fromLive"] == nil)
        // Not a command with a live form.
        #expect(throws: EngineError.self) { try LiveRetouchStroke.begin(s, "paint.dodge", params("paint.sponge", Self.points)) }
        #expect(throws: EngineError.self) { try LiveRetouchStroke.begin(s, "paint.blur", params("paint.blur", [StrokePoint(.infinity, 3, 1)])) }
    }
}
