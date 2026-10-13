// Port of photocraft-engine (crates/engine/src/redeye_cmds.rs `mod tests`) and photocraft-algo (crates/algo/src/redeye.rs `mod tests`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import PCDocument
@testable import PCEngine
import PCFoundation
import PCPaint
import Testing

@Suite struct RedEyeTests {
    typealias K = RedEyeCommands.Kernel

    func session(_ w: Int, _ h: Int, _ depth: Int, _ mode: String) throws -> Session {
        let s = Session()
        try s.execute("file.new", ["width": .int(w), "height": .int(h), "depth": .int(depth), "mode": .string(mode)])
        return s
    }

    func rgba(_ s: Session, _ x: Int32, _ y: Int32) -> SIMD4<Float> {
        guard let d = s.active, let id = d.activeLayer, let surf = d.doc.layer(id)?.surface else { return .zero }
        return surf.rgba(x: x, y: y)
    }

    func paintLayer(_ s: Session, _ f: (Int32, Int32) -> SIMD4<Float>) throws {
        try s.edit("setup") { doc, active in
            let b = doc.bounds
            guard let id = active else { return }
            _ = doc.withRaster(of: id) { surf in
                let fmt = surf.format
                var data: [Float] = []
                for y in b.y0..<b.y1 { for x in b.x0..<b.x1 { data += fromRGBA(fmt, f(x, y)) } }
                surf.writeRegion(b, data)
            }
        }
    }

    func redDisc(_ cx: Int32, _ cy: Int32, _ r: Int32) -> (Int32, Int32) -> SIMD4<Float> {
        { x, y in
            let d = hypot(Float(x - cx), Float(y - cy))
            if d <= 1.2 { return SIMD4(1, 1, 1, 1) }
            if d <= Float(r) { return SIMD4(0.95, 0.10, 0.10, 1) }
            return SIMD4(0.38, 0.28, 0.16, 1)
        }
    }

    @Test func redEyeCorrectsADiscAtEveryDepthAndUndoes() throws {
        for depth in [8, 16, 32] {
            let s = try session(64, 64, depth, "rgb")
            try paintLayer(s, redDisc(32, 32, 8))
            let before = rgba(s, 32, 26)
            #expect(before.x > 0.8, "setup \(before)")
            let r = try s.execute("paint.redEye", ["x": 32, "y": 32])
            #expect((r["pixels"]?.intValue ?? 0) > 0, "\(r)")
            let after = rgba(s, 32, 26)
            #expect(after.x < before.x - 0.2, "depth \(depth): \(after) vs \(before)")
            let catchlight = rgba(s, 32, 32)
            #expect(catchlight.x >= 0.9 && catchlight.y >= 0.9, "catchlight \(catchlight)")
            #expect(s.undo())
            let restored = rgba(s, 32, 26)
            for c in 0..<3 { #expect(abs(restored[c] - before[c]) < 0.02, "undo depth \(depth)") }
            #expect(s.redo())
            let redone = rgba(s, 32, 26)
            for c in 0..<3 { #expect(abs(redone[c] - after[c]) < 0.02, "redo depth \(depth)") }
        }
    }

    @Test func missAndBadParamsAreErrors() throws {
        let s = try session(32, 32, 8, "rgb")
        try paintLayer(s) { _, _ in SIMD4(0.1, 0.2, 0.8, 1) }
        #expect(throws: EngineError.other(RedEyeCommands.miss)) { try s.execute("paint.redEye", ["x": 16, "y": 16]) }
        let bad: [JSONValue] = [
            [:], ["x": nil, "y": 1], ["points": .array((0..<65).map { [.int($0), 0] })], ["x": "nope", "y": 1], ["points": []],
        ]
        for p in bad { #expect(throws: EngineError.self, "\(p)") { try s.execute("paint.redEye", p) } }
        do {
            try s.execute("paint.redEye", ["x": 8, "y": 8, "pupilSize": 10_000.0])
            Issue.record("window cap")
        } catch {
            #expect(String(describing: error).contains("512"), "window cap")
        }
        _ = try? s.execute("paint.redEye", ["x": 8, "y": 8, "pupilSize": 0])
        _ = try? s.execute("paint.redEye", ["x": 8, "y": 8, "pupilSize": 101])
        let t = try session(64, 64, 8, "rgb")
        try paintLayer(t, redDisc(32, 32, 8))
        #expect(throws: Never.self, "pupilSize 0 clamps") { try t.execute("paint.redEye", ["x": 32, "y": 32, "pupilSize": 0]) }
        #expect(t.undo())
        #expect(throws: Never.self, "pupilSize 101 clamps") { try t.execute("paint.redEye", ["x": 32, "y": 32, "pupilSize": 101]) }
    }

    /// The type-layer half of photocraft's test needs `type.create` (another module): a shape
    /// layer stands in.
    @Test func disabledWithoutAPaintableTarget() throws {
        #expect(!Session().isEnabled("paint.redEye"))
        let s = try session(32, 32, 8, "rgb")
        #expect(s.isEnabled("paint.redEye"))
        try s.execute("layer.setProps", ["locks": ["pixels": true]])
        #expect(!s.isEnabled("paint.redEye"), "locked pixels disable the tool")
        do {
            try s.execute("paint.redEye", ["x": 8, "y": 8])
            Issue.record("locked layer")
        } catch {
            #expect(String(describing: error).lowercased().contains("locked"), "\(error)")
        }
    }

    @Test func severalPointsAreOneHistoryStep() throws {
        let s = try session(80, 40, 8, "rgb")
        try paintLayer(s) { x, y in
            (abs(x - 20) <= 6 && abs(y - 20) <= 6) || (abs(x - 60) <= 6 && abs(y - 20) <= 6) ? SIMD4(0.95, 0.1, 0.1, 1) : SIMD4(0.2, 0.2, 0.2, 1)
        }
        let past = s.active!.history.pastCount
        try s.execute("paint.redEye", ["points": [[20, 20], [60, 20]]])
        #expect(s.active!.history.pastCount == past + 1)
        #expect(rgba(s, 20, 20).x < 0.7)
        #expect(rgba(s, 60, 20).x < 0.7)
    }

    @Test func cmykDocumentKeepsUntouchedPixelsBitExact() throws {
        let s = try session(64, 64, 8, "cmyk")
        #expect(s.active!.doc.pixelFormat.mode == .cmyk)
        // Rich black (all four inks) around the eye: a naive RGBA round trip regenerates K.
        let disc = redDisc(32, 32, 8)
        try s.edit("setup") { doc, active in
            let b = doc.bounds
            _ = doc.withRaster(of: active!) { surf in
                let fmt = surf.format, n = fmt.channels
                var data: [Float] = []
                for y in b.y0..<b.y1 {
                    for x in b.x0..<b.x1 {
                        if abs(x - 32) <= 10 && abs(y - 32) <= 10 {
                            data += fromRGBA(fmt, disc(x, y))
                        } else {
                            var px: [Float] = [0.6, 0.5, 0.5, 0.7]
                            while px.count < n { px.append(1) }
                            data += px.prefix(n)
                        }
                    }
                }
                surf.writeRegion(b, data)
            }
        }
        func raw(_ x: Int32, _ y: Int32) -> [Float] {
            s.active!.doc.layer(s.active!.activeLayer!)!.surface!.readRegion(PixelRect(x0: x, y0: y, x1: x + 1, y1: y + 1))
        }
        let probes: [(Int32, Int32)] = [(32, 18), (2, 2), (50, 40)]
        let before = probes.map { raw($0.0, $0.1) }
        let r = try s.execute("paint.redEye", ["x": 32, "y": 32])
        #expect((r["pixels"]?.intValue ?? 0) > 0, "\(r)")
        for (i, p) in probes.enumerated() { #expect(raw(p.0, p.1) == before[i], "untouched CMYK pixel \(p) inside the window changed") }
        #expect(rgba(s, 32, 26).x < 0.7, "pupil corrected")
    }

    @Test func grayDocumentMisses() throws {
        let s = try session(24, 24, 16, "gray")
        try paintLayer(s) { _, _ in SIMD4(0.5, 0.5, 0.5, 1) }
        #expect(s.active!.doc.pixelFormat.mode == .grayscale)
        #expect(throws: EngineError.self) { try s.execute("paint.redEye", ["x": 12, "y": 12]) }
    }

    // MARK: Kernel (photocraft-algo redeye.rs)

    func sample(_ w: Int, _ h: Int, _ f: (Int, Int) -> SIMD4<Float>) -> [SIMD4<Float>] {
        var px = [SIMD4<Float>](repeating: .zero, count: w * h)
        for y in 0..<h { for x in 0..<w { px[y * w + x] = f(x, y) } }
        return px
    }

    func disc(_ x: Int, _ y: Int, _ cx: Float, _ cy: Float, _ r: Float) -> Bool { hypot(Float(x) - cx, Float(y) - cy) <= r }

    func portraitPixel(_ x: Int, _ y: Int) -> SIMD4<Float> {
        // Brown that fails R > G+0.15 so the iris is never in the red-eye mask.
        if disc(x, y, 16, 16, 1.2) { return SIMD4(1, 1, 1, 1) }
        if disc(x, y, 16, 16, 10) { return SIMD4(0.95, 0.10, 0.10, 1) }
        return SIMD4(0.38, 0.28, 0.16, 1)
    }

    @Test func haloCoversErodeAndBlurReach() {
        #expect(K.haloRadius() == 1 + Int32((K.sigma * 3).rounded(.up)) + 1)
        #expect(K.haloRadius() == 5)
        #expect(K.searchRadius(50) == 64)
        #expect(K.searchRadius(0) == 8)
        #expect(K.searchRadius(101) == K.searchRadius(100))
        #expect(K.unclampedWindowSide(50).map { $0 < K.maxWindow } == true)
        #expect(K.unclampedWindowSide(10_000) == nil)
        #expect(K.unclampedWindowSide(.nan) == nil)
    }

    @Test func redDiscIsNeutralizedAndIrisIsLeftAlone() {
        let w = 32
        var px = sample(w, w, portraitPixel)
        let irisBefore = px[2 * w + 2]
        let n = K.apply(&px, w, w, click: (16, 16), origin: (0, 0), pupilSize: 50, darken: 100)
        #expect(n > 0)
        // 5 px from the centre: in the red ring, outside the catchlight, inside the eroded mask.
        let after = px[11 * w + 16]
        let neut: Float = (0.10 + 0.10) / 2
        #expect(abs(after.x - after.y) < 0.08 && abs(after.x - after.z) < 0.08, "red no longer dominates: \(after)")
        #expect(abs(after.x - neut * 0.55) < 0.08, "R ≈ (G+B)/2 then darkened: \(after)")
        #expect(K.luma(after) < K.luma(SIMD4(0.95, 0.10, 0.10, 1)) - 0.05, "pupil darkened")
        let irisAfter = px[2 * w + 2]
        for c in 0..<4 { #expect(abs(irisAfter[c] - irisBefore[c]) < 1e-5) }
        let catchlight = px[16 * w + 16]
        #expect(catchlight.x >= 0.9 && catchlight.y >= 0.9 && catchlight.z >= 0.9)
    }

    @Test func grayPixelsAreNotTreatedAsRedEye() {
        let w = 16
        var px = sample(w, w) { _, _ in SIMD4(0.4, 0.4, 0.4, 1) }
        #expect(K.apply(&px, w, w, click: (8, 8), origin: (0, 0), pupilSize: 50, darken: 50) == 0)
        #expect(px[8 * w + 8] == SIMD4(0.4, 0.4, 0.4, 1))
    }

    func applyTiled(_ src: [SIMD4<Float>], _ w: Int, _ h: Int, _ click: (Int32, Int32), _ tile: Int, _ halo: Int) -> [SIMD4<Float>] {
        var out = src
        var y0 = 0
        while y0 < h {
            var x0 = 0
            while x0 < w {
                let (x1, y1) = (min(x0 + tile, w), min(y0 + tile, h))
                let (rx0, ry0) = (max(x0 - halo, 0), max(y0 - halo, 0))
                let (rx1, ry1) = (min(x1 + halo, w), min(y1 + halo, h))
                let (bw, bh) = (rx1 - rx0, ry1 - ry0)
                var buf = [SIMD4<Float>](repeating: .zero, count: bw * bh)
                for yy in 0..<bh { for xx in 0..<bw { buf[yy * bw + xx] = src[(ry0 + yy) * w + rx0 + xx] } }
                _ = K.apply(&buf, bw, bh, click: click, origin: (Int32(rx0), Int32(ry0)), pupilSize: 50, darken: 50)
                for yy in y0..<y1 { for xx in x0..<x1 { out[yy * w + xx] = buf[(yy - ry0) * bw + (xx - rx0)] } }
                x0 += tile
            }
            y0 += tile
        }
        return out
    }

    @Test func tileSeamMatchesAnUntiledReference() {
        let w = 128
        // A red half-plane ending on the 64 px tile boundary: the mask edge is where a short halo fails.
        let src = sample(w, w) { x, _ in x < 64 ? SIMD4(0.95, 0.10, 0.10, 1) : SIMD4(0.38, 0.28, 0.16, 1) }
        var reference = src
        _ = K.apply(&reference, w, w, click: (60, 64), origin: (0, 0), pupilSize: 50, darken: 50)
        func maxErr(_ a: [SIMD4<Float>], _ b: [SIMD4<Float>]) -> Float {
            zip(a, b).reduce(0) { m, p in max(m, abs(p.0.x - p.1.x), abs(p.0.y - p.1.y), abs(p.0.z - p.1.z)) }
        }
        let tiled = applyTiled(src, w, w, (60, 64), 64, Int(K.haloRadius()))
        let err = maxErr(reference, tiled)
        #expect(err < 1e-4, "tiled vs reference max err \(err)")
        // Reach is erode (1) + ceil(σ×3) (3). A 1 px halo cannot cover that; the documented halo can.
        let short = applyTiled(src, w, w, (60, 64), 64, 1)
        #expect(maxErr(reference, short) > err + 1e-4)
    }

    @Test func emptyOrMismatchedBufferChangesNothing() {
        var px: [SIMD4<Float>] = []
        #expect(K.apply(&px, 0, 0, click: (0, 0), origin: (0, 0), pupilSize: 50, darken: 50) == 0)
        var tiny = [SIMD4<Float>](repeating: SIMD4(0.95, 0.1, 0.1, 1), count: 4)
        #expect(K.apply(&tiny, 8, 8, click: (1, 1), origin: (0, 0), pupilSize: 50, darken: 50) == 0)
    }
}
