// Port of photocraft's document save/open round trips (crates/engine/src/file_cmds/tests.rs `save_*`, crates/ui-egui save identity tests), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
@testable import PCEngine
import PCDocument
import PCFoundation
import PCPlatform
import Testing

/// A temporary folder for a test's files.
func ioDir(_ name: String) throws -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("pcengine-io-\(name)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

/// Where the Photoshop oracle agent sweeps PSDs from: `PCIO_EXPORT_DIR`, as for PCIO's tests (e.g.
/// `$PHOTOCRAFT_FIXTURES/pcio-exports`), when set and not `none`. Unset, nothing is dropped (never
/// into the fixtures folder by default).
let pcioExports: URL? = {
    guard let p = ProcessInfo.processInfo.environment["PCIO_EXPORT_DIR"], !p.isEmpty, p != "none" else { return nil }
    return URL(fileURLWithPath: p)
}()

/// Copies a PSD/PSB a test wrote into the oracle agent's folder, when there is one.
func dropForOracle(_ file: URL, as name: String) {
    guard let pcioExports else { return }
    try? FileManager.default.createDirectory(at: pcioExports, withIntermediateDirectories: true)
    let dest = pcioExports.appendingPathComponent("pcengine-\(name)")
    try? FileManager.default.removeItem(at: dest)
    try? FileManager.default.copyItem(at: file, to: dest)
}

@Suite struct FileIOTests {
    func sample() throws -> Session {
        let s = Session()
        try s.execute("file.new", ["width": 48, "height": 32, "name": "Sample"])
        try s.execute("layer.new.layer", ["name": "Ink"])
        try s.execute("select.rect", ["x": 4, "y": 4, "width": 16, "height": 12])
        try s.execute("edit.fill", ["color": "#cc2244"])
        try s.execute("select.deselect")
        try s.execute("layer.setProps", ["opacity": 0.75, "blend": "multiply"])
        try s.execute("type.create", ["x": 22, "y": 24, "text": "Hi", "size": 14, "color": "#1040ff"])
        return s
    }

    @Test func psdSaveAsBecomesTheDocumentsFileAndReopens() throws {
        let dir = try ioDir("psd")
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = try sample()
        let path = dir.appendingPathComponent("round.psd").path
        let r = try s.execute("file.saveAs", ["path": .string(path)])
        #expect(r["copy"] == false)
        #expect(s.active?.path == path && s.active?.doc.name == "round.psd" && s.active?.isDirty == false)
        dropForOracle(URL(fileURLWithPath: path), as: "file-saveAs-round.psd")
        // Save writes back in place; a journaled save replays.
        try s.execute("layer.setProps", ["opacity": 0.5])
        #expect(s.active?.isDirty == true)
        try s.execute("file.save")
        #expect(s.active?.isDirty == false)
        try s.execute("layer.setProps", ["opacity": 0.75])
        try s.execute("file.save")
        // Reopen: same layers, same composite.
        let before = try s.services.renderer.composite(s.active!.doc, rect: s.active!.doc.bounds)
        let o = try s.execute("file.open", ["path": .string(path)])
        let i = try #require(o["document"]?.intValue)
        let d = s.documents[i].doc
        #expect(d.layers.map(\.name) == s.documents[0].doc.layers.map(\.name))
        #expect(d.layers[1].blend == .multiply && abs(d.layers[1].opacity - 0.75) < 0.01)
        #expect(abs(d.layers[2].opacity - 0.75) < 0.01, "the last Save wrote the type layer's opacity")
        if case .text = d.layers[2].content {} else { Issue.record("the type layer came back as \(d.layers[2].content.kindName)") }
        let after = try s.services.renderer.composite(d, rect: d.bounds)
        #expect(zip(before, after).allSatisfy { abs($0 - $1) <= 2.0 / 255 }, "the reopened PSD composites like the saved document")
        #expect(s.recentFiles.first == path)
    }

    @Test func pcraftRoundTripsExactly() throws {
        let dir = try ioDir("pcraft")
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = try sample()
        let path = dir.appendingPathComponent("native.pcraft").path
        try s.execute("file.saveAs", ["path": .string(path)])
        let saved = s.active!.doc
        let (i, warnings, _) = try s.openFile(path)
        #expect(warnings.isEmpty, "\(warnings)")
        let back = s.documents[i].doc
        #expect(back.layers.count == saved.layers.count)
        #expect(back.layers[1].surface?.readRegion(back.bounds) == saved.layers[1].surface?.readRegion(saved.bounds))
    }

    /// A lossy WebP reopens with its own libwebp quality (PCPlatform `SourceSettings.webpQuality`)
    /// instead of photocraft's default 75, so File › Save writes it back the way it came: saved at
    /// 40, reopened and saved again without a quality, it is still 40 ± 1.
    @Test func aReopenedLossyWebPSavesAtItsOwnQuality() throws {
        let dir = try ioDir("webp-quality")
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = Session()
        try s.execute("file.new", ["width": 96, "height": 64, "name": "Grain"])
        // Varied content, so the encoder's segments carry the quality.
        try s.updateActive { st in
            let r = st.doc.bounds
            var rng: UInt64 = 7
            let px = (0..<r.area).map { i -> SIMD4<Float> in
                rng = rng &* 6364136223846793005 &+ 1442695040888963407
                let n = Float(rng >> 40) / Float(1 << 24)
                let (x, y) = (Float(i % r.width) / Float(r.width), Float(i / r.width) / Float(r.height))
                return SIMD4(x * 0.7 + n * 0.3, y * 0.6 + n * 0.2, 0.5 + 0.4 * sin(x * 9) * n, 1)
            }
            st.doc.withRaster(of: st.doc.layers[0].id) { $0.writeRGBA(r, px) }
        }
        func quality(_ path: String) throws -> Int? { SourceSettings.webpQuality(try Data(contentsOf: URL(fileURLWithPath: path))) }
        // Encoded at libwebp quality 40 (`file.saveAs` takes Photoshop's 0…12 scale).
        let first = dir.appendingPathComponent("q40.webp").path
        let doc = try #require(s.active?.doc)
        try Data(EngineIO.export(doc, as: "q40.webp", services: s.services, quality: 40).bytes).write(to: URL(fileURLWithPath: first))
        let saved = try #require(try quality(first))
        #expect(abs(saved - 40) <= 1, "saved at \(saved)")
        let (i, _, _) = try s.openFile(first)
        let e = s.documents[i].doc.fileEncoding
        #expect(e.webpLossless == false)
        let reopened = try #require(e.webpQuality.map(Int.init))
        #expect(abs(reopened - 40) <= 1, "reopened at \(reopened)")
        _ = s.setActive(i)
        let again = dir.appendingPathComponent("again.webp").path
        try s.execute("file.saveAs", ["path": .string(again)])
        let resaved = try #require(try quality(again))
        #expect(abs(resaved - reopened) <= 1 && abs(resaved - 40) <= 2, "re-saved at \(resaved)")
    }

    /// A flat file that can't hold the document is written as a copy (photocraft `saves_copy`):
    /// the document keeps no path and stays unsaved. A TIFF holds the layers, so it becomes the
    /// document's file; so does a flat file for a plain raster.
    @Test func flatFormatsAreCopiesUnlessTheyHoldTheDocument() throws {
        let dir = try ioDir("flat")
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = try sample()
        for ext in ["png", "jpg", "webp", "bmp", "tga", "gif"] {
            _ = s.setActive(0)
            let path = dir.appendingPathComponent("copy.\(ext)").path
            let r = try s.execute("file.saveAs", ["path": .string(path), "quality": 10])
            #expect(r["copy"] == true, "\(ext)")
            #expect(FileManager.default.fileExists(atPath: path), "\(ext)")
            #expect(s.active?.path == nil, "\(ext): a flat save is a copy")
            let (i, _, _) = try s.openFile(path)
            #expect(s.documents[i].doc.size == PixelSize(width: 48, height: 32), "\(ext)")
        }
        // Save without a layered file of its own asks for Save As.
        _ = s.setActive(0)
        #expect(throws: EngineError.self) { try s.execute("file.save") }
        // A TIFF keeps the layers (unless TIFF Options discards them: a copy).
        let tif = dir.appendingPathComponent("layers.tif").path
        let r = try s.execute("file.saveAs", ["path": .string(tif)])
        #expect(r["copy"] == false && s.active?.path == tif)
        #expect(try s.execute("file.saveAs", ["path": .string(dir.appendingPathComponent("flat.tif").path), "tiffLayers": false])["copy"] == true)
        let (t, _, _) = try s.openFile(tif)
        #expect(s.documents[t].doc.layers.count == s.documents[0].doc.layers.count, "the TIFF holds the layers")
        // A plain raster saved as PNG becomes that file.
        let plain = Session()
        try plain.execute("file.new", ["width": 8, "height": 8])
        let png = dir.appendingPathComponent("plain.png").path
        #expect(try plain.execute("file.saveAs", ["path": .string(png)])["copy"] == false)
        #expect(plain.active?.path == png && plain.active?.isDirty == false)
    }

    @Test func recoveryAutosavesAndRestores() throws {
        let dir = try ioDir("recovery")
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = try sample()
        s.enableRecovery(dir)
        s.autosaveDirty(force: true)
        // Wait for the background write.
        var done: [(doc: UInt64, revision: UInt64, error: String?)] = []
        for _ in 0..<200 where done.isEmpty {
            done = s.recoveryResults()
            if done.isEmpty { Thread.sleep(forTimeInterval: 0.05) }
        }
        #expect(done.first?.error == nil)
        // A new session finds and restores it.
        let t = Session()
        t.enableRecovery(dir)
        let entries = t.recoverableDocuments()
        #expect(entries.count == 1)
        let i = try t.restore(try #require(entries.first))
        #expect(t.documents[i].doc.layers.count == s.active!.doc.layers.count)
        #expect(t.documents[i].isDirty)
    }
}
