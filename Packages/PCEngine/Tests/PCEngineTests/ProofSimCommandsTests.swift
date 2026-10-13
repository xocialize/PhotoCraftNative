// Port of photocraft-engine (crates/engine/src/proof_sim.rs `mod tests`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// `s.color.display_lut(doc, n)` maps to `ProofSimCommands.displayLUT(s, st, size: n)` (nil on the
// plain path) and `canvas_lut` / `gpu_canvas_lut` to `ColorCommands.canvasDisplay(…, includeHDR:)`.

import Foundation
import PCDocument
@testable import PCEngine
import PCFoundation
import PCPlatform
import Testing

@Suite struct ProofSimCommandsTests {
    func session(_ mode: String, _ depth: Int) throws -> Session {
        let s = Session()
        try s.execute("file.new", ["width": 8, "height": 8, "mode": .string(mode), "depth": .int(depth)])
        return s
    }

    func sample(_ lut: PCPlatform.DisplayLUT, _ idx: (Int, Int, Int)) -> SIMD3<Float> {
        let n = lut.size
        let v = lut.data[idx.0 + idx.1 * n + idx.2 * n * n]
        return SIMD3(v.x, v.y, v.z)
    }

    @Test func dichromatKeepsNeutralsAndMergesRedGreen() {
        for protan in [true, false] {
            let w = ProofSimCommands.dichromat(SIMD3(1, 1, 1), protan: protan)
            #expect([w.x, w.y, w.z].allSatisfy { abs($0 - 1) < 0.02 }, "\(w)")
            let g = ProofSimCommands.dichromat(SIMD3(0.2, 0.2, 0.2), protan: protan)
            #expect([g.x, g.y, g.z].allSatisfy { abs($0 - 0.2) < 0.02 }, "\(g)")
            // Red and green become (nearly) indistinguishable in hue.
            let r = ProofSimCommands.dichromat(SIMD3(1, 0, 0), protan: protan)
            let gr = ProofSimCommands.dichromat(SIMD3(0, 1, 0), protan: protan)
            #expect(abs(r.x - r.y) < 0.15 && abs(gr.x - gr.y) < 0.15, "\(r) \(gr)")
            // Blue stays blue.
            #expect(ProofSimCommands.dichromat(SIMD3(0, 0, 1), protan: protan).z > 0.8)
        }
        // Protanopes see red much darker than deuteranopes do.
        #expect(ProofSimCommands.dichromat(SIMD3(1, 0, 0), protan: true).x < ProofSimCommands.dichromat(SIMD3(1, 0, 0), protan: false).x)
    }

    @Test func platesAndSimulationsBuildLUTs() throws {
        for depth in [8, 16, 32] {
            let s = try session("rgb", depth)
            for id in ["view.proofSetup.workingCyanPlate", "view.proofSetup.workingBlackPlate", "view.proofSetup.workingCmyPlate",
                       "view.proofSetup.legacyMacintoshRgb", "view.proofSetup.colorBlindnessProtanopia", "view.proofSetup.colorBlindnessDeuteranopia"] {
                let r = try s.execute(id)
                #expect(r["proofColors"] == true)
                let st = s.active!
                #expect(ColorCommands.proof(st).kind.id == String(id.dropFirst("view.proofSetup.".count)))
                let lut = try #require(try ProofSimCommands.displayLUT(s, st, size: 5))
                #expect(lut.data.count == 125)
                #expect(try ColorCommands.canvasDisplay(s, st).lut != nil)
            }
        }
    }

    @Test func platePreviewsAreGrayAndTrackInk() throws {
        let s = try session("rgb", 8)
        try s.execute("view.proofSetup.workingCyanPlate")
        let lut = try #require(try ProofSimCommands.displayLUT(s, s.active!, size: 5))
        // Pure cyan: heavy cyan plate → dark gray; white: no ink → white; red: little cyan.
        let cyan = sample(lut, (0, 4, 4)), white = sample(lut, (4, 4, 4)), red = sample(lut, (4, 0, 0))
        for c in [cyan, white, red] { #expect(abs(c.x - c.y) < 0.03 && abs(c.y - c.z) < 0.03, "plates are gray: \(c)") }
        #expect(white.x > 0.9, "\(white)")
        #expect(cyan.x < red.x && cyan.x < 0.6, "cyan \(cyan) red \(red)")
        // Back to the plain working CMYK proof via Proof Setup.
        try s.execute("view.proofSetup", ["profile": "working-cmyk"])
        #expect(ColorCommands.proof(s.active!).kind == .profile)
    }

    @Test func legacyMacIsDarkerInMidtones() throws {
        let s = try session("rgb", 8)
        try s.execute("view.proofSetup.legacyMacintoshRgb")
        let lut = try #require(try ProofSimCommands.displayLUT(s, s.active!, size: 5))
        let mid = sample(lut, (2, 2, 2)), white = sample(lut, (4, 4, 4))
        // 0.5^1.8 = 0.287 linear vs 0.214 for sRGB 0.5: the gamma-1.8 display is brighter.
        #expect(mid.x > 0.52 && mid.x < 0.62, "\(mid)")
        #expect(white.x > 0.99)
    }

    @Test func thirtyTwoBitPreviewOptions() throws {
        let e = try session("rgb", 8)
        #expect(throws: EngineError.self, "8-bit: disabled") { try e.execute("view.thirtyTwoBitPreviewOptions", ["exposure": 1]) }
        let s = try session("rgb", 32)
        #expect(try ColorCommands.canvasDisplay(s, s.active!).isIdentity)
        let r = try s.execute("view.thirtyTwoBitPreviewOptions", ["exposure": 1.0, "gamma": 1.0])
        #expect(r["exposure"] == 1.0)
        #expect(ProofSimCommands.hdrPreview(s.active!) != nil)
        let lut = try #require(try ProofSimCommands.displayLUT(s, s.active!, size: 5))
        // +1 stop doubles linear light: sRGB 0.25 (0.0508 linear) → 0.1016 linear ≈ 0.354 sRGB.
        let q = sample(lut, (1, 1, 1))
        #expect(abs(q.x - 0.354) < 0.02, "\(q)")
        #expect(try !ColorCommands.canvasDisplay(s, s.active!).isIdentity)
        // The GPU canvas applies it in its shader: its LUT leaves it out (none for sRGB).
        #expect(ProofSimCommands.hdrPreview(s.active!) == ProofSimCommands.HdrPreview(highlightCompression: false, exposure: 1, gamma: 1))
        #expect(try ColorCommands.canvasDisplay(s, s.active!, includeHDR: false).isIdentity)
        // Highlight Compression: identity mapping, so no LUT.
        try s.execute("view.thirtyTwoBitPreviewOptions", ["method": "highlightCompression"])
        #expect(ProofSimCommands.hdrPreview(s.active!) == nil)
        #expect(throws: EngineError.self) { try s.execute("view.thirtyTwoBitPreviewOptions", ["method": "nope"]) }
        // Clamped ranges.
        let c = try s.execute("view.thirtyTwoBitPreviewOptions", ["method": "exposureGamma", "exposure": 99, "gamma": 0])
        #expect(c["exposure"] == 20.0)
        #expect(abs((c["gamma"]?.doubleValue ?? 0) - 0.1) < 1e-6)
    }
}
