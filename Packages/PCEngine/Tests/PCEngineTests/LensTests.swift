// Port of photocraft-engine (crates/engine/src/lens_cmds.rs `mod tests`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import PCAlgo
import PCDocument
@testable import PCEngine
import PCFoundation
import PCPlatform
import Testing

@Suite struct LensTests {
    typealias L = LensCommands

    func session(_ depth: Int) throws -> Session {
        let s = Session()
        try s.execute("file.new", ["width": 120, "height": 80, "depth": .int(depth)])
        try s.execute("layer.new.layer", ["name": "grid"])
        try s.edit("grid") { doc, active in
            guard let id = active else { return }
            _ = doc.withRaster(of: id) { surf in
                let fmt = surf.format
                for y: Int32 in 0..<80 {
                    for x: Int32 in 0..<120 {
                        let v: Float = x % 12 < 2 || y % 12 < 2 ? 0.9 : 0.35
                        surf.setPixel(x: x, y: y, fmt.components(fromRGBA: SIMD4(v, v * 0.9, v * 0.7, 1)))
                    }
                }
            }
        }
        return s
    }

    func activePx(_ s: Session, _ x: Int32, _ y: Int32) -> SIMD4<Float> {
        guard let d = s.active, let id = d.activeLayer, let surf = d.doc.layer(id)?.surface else { return SIMD4(-1, -1, -1, -1) }
        return surf.rgba(x: x, y: y)
    }

    func smartFilters(_ s: Session) -> [SmartFilter] {
        guard let d = s.active, let id = d.activeLayer, case .smart(let sm)? = d.doc.layer(id)?.content else { return [] }
        return sm.smartFilters
    }

    @Test func lensCorrectionRunsUndoesAndResolvesProfiles() throws {
        for depth in [8, 16, 32] {
            let s = try session(depth)
            #expect(s.isEnabled(L.lens))
            let before = activePx(s, 1, 1)
            let r = try s.execute(L.lens, ["distortion": -40, "vignetteAmount": -50])
            #expect(r["ms"]?.doubleValue != nil)
            let after = activePx(s, 1, 1)
            #expect(after.w < 0.5, "depth \(depth): corner cleared by transparency edge: \(after)")
            _ = s.undo()
            #expect(activePx(s, 1, 1) == before)
        }
        // EXIF-driven auto profile.
        let s = try session(8)
        try s.edit("exif") { doc, _ in
            doc.metadata.exif = Exif.build(Exif.CameraInfo(focalLength: 16, focalLength35mm: 24))
        }
        var r = try s.execute(L.lens, ["profile": "auto", "autoScale": true, "edge": "edgeExtension"])
        #expect(r["params"]?["profile"] == "generic")
        #expect(r["params"]?["focalLength"] == 24.0)
        #expect((r["scale"]?.doubleValue ?? 0) >= 100)
        r = try s.execute(L.lens, ["straighten": [[0, 0], [100, 5]]])
        #expect(abs((r["angle"]?.doubleValue ?? 0) + 2.862) < 0.01, "\(r)")
        #expect(throws: (any Error).self) { try s.execute(L.lens, ["edge": "rainbow"]) }
        #expect(throws: (any Error).self) { try s.execute(L.lens, ["profile": "zeiss"]) }
    }

    @Test func lensCorrectionAsSmartFilter() throws {
        let s = try session(8)
        try GalleryTests.makeSmartObject(s)
        let r = try s.execute(L.lens, ["vignetteAmount": 80, "edge": "edgeExtension"])
        let d = try #require(s.active)
        let lid = LayerId(try #require(r["layer"]?.uint64Value))
        guard case .smart(let sm)? = d.doc.layer(lid)?.content else {
            Issue.record("smart")
            return
        }
        #expect(sm.smartFilters.count == 1)
        #expect(sm.smartFilters.first?.command == L.lens)
        let corner = activePx(s, 3, 3)
        #expect(corner.x > 0.4, "\(corner)")
    }

    @Test func adaptiveWideAngleStraightens() throws {
        let s = try session(8)
        let r = try s.execute(L.wide, ["model": "fisheye", "focalLength": 10,
                                       "constraints": [["a": [10, 15], "b": [110, 15], "orientation": "horizontal"]]])
        #expect(r["model"] == "fisheye")
        #expect((r["residual"]?.doubleValue ?? 99) < 2, "\(r)")
        #expect(throws: (any Error).self) { try s.execute(L.wide, ["constraints": [["a": [0, 0]]]]) }
        // Smart filter re-render.
        let t = try session(16)
        try GalleryTests.makeSmartObject(t)
        try t.execute(L.wide, ["model": "perspective", "scale": 90])
        #expect(activePx(t, 1, 1).w < 0.5)
    }

    @Test func cameraRawFilterOnLayersSelectionAndSmartObjects() throws {
        for depth in [8, 16, 32] {
            let s = try session(depth)
            #expect(s.isEnabled(L.raw))
            let before = activePx(s, 60, 40)
            try s.execute(L.raw, ["exposure": 1.0, "vibrance": 30, "clarity": 20])
            let after = activePx(s, 60, 40)
            #expect(after.y > before.y + 0.05, "depth \(depth): \(before) → \(after)")
            _ = s.undo()
        }
        // Selection limits it.
        let s = try session(8)
        try s.execute("select.rect", ["x": 0, "y": 0, "width": 60, "height": 80])
        let insideBefore = activePx(s, 10, 40)
        let outsideBefore = activePx(s, 100, 40)
        try s.execute(L.raw, ["exposure": -1.0])
        #expect(activePx(s, 10, 40).y < insideBefore.y)
        #expect(activePx(s, 100, 40) == outsideBefore)
        #expect(throws: (any Error).self) { try s.execute(L.raw, ["exposure": "bright"]) }
        let legacyCurve: JSONValue = [[0, 0], [60, 40], [60, 200], [255, 255]]
        #expect(throws: (any Error).self, "new curves are validated") { try s.execute(L.raw, ["pointCurve": legacyCurve]) }
        // A curve an older editor saved must still re-apply as a Smart Filter.
        let d = try #require(s.active)
        let active = try #require(d.activeLayer)
        let surf = try #require(d.doc.layer(active)?.surface)
        let stored = L.applyToSurface(L.raw, ["pointCurve": legacyCurve, "exposure": 1.0], surf, canvas: PixelRect(x0: 0, y0: 0, x1: 120, y1: 80))
        #expect(stored != nil, "a stored legacy curve must not drop the whole filter")
        // Smart filter.
        let t = try session(8)
        try GalleryTests.makeSmartObject(t)
        try t.execute(L.raw, ["saturation": -100])
        let p = activePx(t, 60, 40)
        #expect(abs(p.x - p.z) < 0.01, "\(p)")
    }

    @Test func cameraRawDecodesLightWithTheDocumentsCurve() throws {
        // A raw opens in ProPhoto (gamma 1.8): the filter keeps that with its settings, so Whites,
        // Blacks, Shadows and Highlights work on the same light as when it was applied.
        let s = try session(16)
        try s.execute("edit.assignProfile", ["profile": "prophoto-compat"])
        let sd = try #require(s.active)
        #expect(L.encodingGamma(sd.doc) == 1.8)
        try GalleryTests.makeSmartObject(s)
        try s.execute(L.raw, ["shadows": 40, "whites": -30])
        #expect(smartFilters(s).first?.params["encodingGamma"] == 1.8)
        // sRGB documents use the sRGB curve, the default, and store nothing.
        let t = try session(8)
        let td = try #require(t.active)
        #expect(L.encodingGamma(td.doc) == 0)
        try GalleryTests.makeSmartObject(t)
        try t.execute(L.raw, ["shadows": 40])
        #expect(smartFilters(t).count == 1)
        #expect(smartFilters(t).first?.params["encodingGamma"] == nil)
    }

    @Test func cameraRawRejectsAnAreaTooLargeToDevelop() throws {
        // photocraft #962: `area.width() * area.height()` overflowed u32 on a legal 65536×65536
        // canvas.
        let s = Session()
        try s.execute("file.new", ["width": 8, "height": 8, "background": "transparent"])
        try s.execute("image.canvasSize", ["width": 65536, "height": 65536, "extensionColor": "transparent"])
        do {
            try s.execute(L.raw, ["exposure": 1])
            Issue.record("a 65536×65536 canvas was developed")
        } catch {
            if case .badParams? = error as? EngineError {} else { Issue.record("\(error)") }
            #expect("\(error)".contains("too large"), "\(error)")
        }
        // The surface function itself never overflows either: an oversized area is left alone.
        let d = try #require(s.active)
        let active = try #require(d.activeLayer)
        let surf = try #require(d.doc.layer(active)?.surface)
        let cr = try L.rawParams(L.raw, ["exposure": 1])
        let out = L.cameraRawSurface(surf, PixelRect(x: 0, y: 0, width: 65536, height: 65536), cr)
        #expect(out.contentBounds == surf.contentBounds)
        // A normal document still develops.
        let t = try session(8)
        try t.execute(L.raw, ["exposure": 1])
    }

    @Test func lensCorrectionBatchOverFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pc-lens-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appendingPathComponent("in")
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        let s = try session(8)
        try s.execute("layer.flattenImage", [:])
        let doc = try #require(s.active).doc
        let flat = try s.services.renderer.compositeToSurface(doc, rect: doc.bounds, format: doc.pixelFormat)
        let png = try ImageCodecs.encode(flat, rect: doc.bounds, as: .png)
        for k in 0..<2 { try png.write(to: input.appendingPathComponent("shot\(k).png")) }
        let out = dir.appendingPathComponent("out")
        let r = try s.execute(L.lensBatchId, ["input": .string(input.path), "output": .string(out.path), "vignetteAmount": 60, "edge": "edgeExtension"])
        #expect(r["files"]?.arrayValue?.count == 2, "\(r)")
        #expect(r["errors"]?.arrayValue?.isEmpty == true)
        #expect(FileManager.default.fileExists(atPath: out.appendingPathComponent("shot0.png").path))
        // Not in photocraft's test: a layered PSD opens and saves as a PSD; an unreadable file is
        // reported and the rest of the batch runs.
        let psd = input.appendingPathComponent("layers.psd").path
        try s.saveDocument(to: psd)
        try Data([0x38, 0x42, 0x50, 0x53]).write(to: input.appendingPathComponent("broken.psd"))
        let out2 = dir.appendingPathComponent("out2")
        let r2 = try s.execute(L.lensBatchId, ["input": .string(input.path), "output": .string(out2.path)])
        #expect(r2["files"]?.arrayValue?.count == 3, "\(r2)")
        let errors = r2["errors"]?.arrayValue ?? []
        #expect(errors.count == 1 && (errors.first?["file"]?.stringValue ?? "").hasSuffix("broken.psd"), "\(r2)")
        let corrected = out2.appendingPathComponent("layers.psd")
        #expect(try EngineIO.importPath(corrected.path, services: s.services).document.size == doc.size)
        dropForOracle(corrected, as: "lens-batch.psd")
    }
}
