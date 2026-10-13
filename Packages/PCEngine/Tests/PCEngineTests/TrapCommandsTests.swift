// Port of photocraft-engine (crates/engine/src/trap_cmds.rs `mod tests`) and photocraft-algo's trap tests' invariants, MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import PCAlgo
import PCDocument
@testable import PCEngine
import PCFoundation
import Testing

@Suite struct TrapCommandsTests {
    @Test func trapsACMYKDocument() throws {
        let s = Session()
        try s.execute("file.new", ["width": 8, "height": 4, "mode": "cmyk"])
        // Paint cyan | magenta halves on the Background.
        try s.edit("paint") { doc, active in
            let fmt = doc.pixelFormat
            let ch = fmt.channels
            var data = [Float](repeating: 0, count: 8 * 4 * ch)
            for y in 0..<4 {
                for x in 0..<8 {
                    let o = (y * 8 + x) * ch
                    if x < 4 { data[o] = 1 } else { data[o + 1] = 1 }
                    if fmt.alpha { data[o + ch - 1] = 1 }
                }
            }
            doc.withRaster(of: active!) { $0.writeRegion(PixelRect(x0: 0, y0: 0, x1: 8, y1: 4), data) }
        }
        let r = try s.execute("image.trap", ["width": 1])
        #expect(r["trapped"] == true)
        // The seam now has overlapping inks.
        let st = s.active!
        let surf = st.doc.layer(st.activeLayer!)!.surface!
        let ch = surf.channels
        let d = surf.readRegion(PixelRect(x0: 0, y0: 0, x1: 8, y1: 4))
        #expect(d[3 * ch + 1] > 0.5, "magenta trapped into the cyan edge")
        #expect(d[4 * ch] > 0.5, "cyan trapped into the magenta edge")
        // One history step.
        #expect(st.history.entries.last == "Trap")
    }

    @Test func rejectsNonCMYK() throws {
        let s = Session()
        try s.execute("file.new", ["width": 8, "height": 4, "mode": "rgb"])
        #expect(throws: EngineError.self) { try s.execute("image.trap", ["width": 1]) }
        #expect(s.disabledReason("image.trap") == "Trap needs a CMYK document (Image › Mode › CMYK Color)")
    }

    /// The trap (PCAlgo `Trap.trap`, CPU and the engine's `.auto`) spreads each ink by the direct
    /// window maximum at every radius, only under inked pixels; paper stays paper, alpha untouched.
    @Test func dilationMatchesTheDirectWindowMaximum() throws {
        let (w, h, ch) = (23, 7, 5)
        var px = [Float](repeating: 0, count: w * h * ch)
        var seed: UInt32 = 12345
        for i in px.indices {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            px[i] = (seed >> 8) % 5 == 0 ? Float(seed >> 16 & 255) / 255 : 0
        }
        for backend in [Backend.cpu, .auto] {
            for r in [1, 2, 3, 5, 9, 30] {
                var buf = px
                try Trap.trap(&buf, width: w, height: h, channels: ch, trapWidth: r, on: backend)
                for y in 0..<h {
                    for x in 0..<w {
                        let o = (y * w + x) * ch
                        let inked = (0..<4).contains { px[o + $0] > 1e-4 }
                        for c in 0..<4 {
                            var m: Float = 0
                            for yy in max(y - r, 0)...min(y + r, h - 1) { for xx in max(x - r, 0)...min(x + r, w - 1) { m = max(m, px[(yy * w + xx) * ch + c]) } }
                            #expect(buf[o + c] == (inked ? max(px[o + c], m) : px[o + c]), "\(backend) r \(r) c \(c) (\(x), \(y))")
                        }
                        #expect(buf[o + 4] == px[o + 4])
                    }
                }
            }
        }
        // The engine's helper is the same trap.
        var viaEngine = px, viaAlgo = px
        TrapCommands.trapInks(&viaEngine, width: w, height: h, channels: ch, trap: 3)
        try Trap.trap(&viaAlgo, width: w, height: h, channels: ch, trapWidth: 3, on: .cpu)
        #expect(viaEngine == viaAlgo)
    }
}
