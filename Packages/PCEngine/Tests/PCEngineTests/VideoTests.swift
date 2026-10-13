// Port of photocraft-engine (crates/engine/src/video_cmds/tests.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Skipped: `inspect_reports_video_layer` (Inspect's video fields are not this module's). Fixture
// PNGs are written through PCIO, animated GIFs with the module's own GIF writer, as photocraft's
// tests do.

import Foundation
import PCAlgo
import PCDocument
@testable import PCEngine
import PCFoundation
import Testing

@Suite struct VideoTests {
    func session() throws -> Session {
        let s = Session()
        try s.execute("file.new", ["width": 16, "height": 12])
        return s
    }

    func video(_ s: Session, _ id: LayerId) -> VideoData? { s.active?.doc.layer(id)?.video }
    func frames(_ s: Session, _ id: LayerId) -> Int { video(s, id)?.frames.count ?? -1 }

    func newBlank(_ s: Session) throws -> LayerId {
        LayerId(try #require(try s.execute("layer.videoLayers.newBlankVideoLayer")["layer"]?.uint64Value))
    }

    /// The displayed pixel (2, 2) of layer `id`.
    func layerPixel(_ s: Session, _ id: LayerId) throws -> [Float] {
        guard case .raster(let r)? = s.active?.doc.layer(id)?.content else { Issue.record("not a raster"); return [] }
        return r.pixel(x: 2, y: 2)
    }

    /// Edit › Fill of the active layer with `rgba` (stands in for `edit.fill`, not ported yet).
    func fill(_ s: Session, _ rgba: [Float]) throws {
        try s.edit("Fill") { doc, active in
            guard let id = active else { return }
            let b = doc.bounds
            doc.withRaster(of: id) { $0.fill(b, with: rgba) }
        }
    }

    /// A video layer imported from a red and a green 8×8 PNG (photocraft's tests write the frames
    /// and run New Video Layer from File).
    func footage(_ s: Session, _ name: String) throws -> LayerId {
        let dir = try tmpdir(name)
        try writePNG("\(dir)/f0.png", 8, 8, "#ff0000")
        try writePNG("\(dir)/f1.png", 8, 8, "#00ff00")
        return try layerOf(try s.execute("layer.videoLayers.newVideoLayerFromFile", ["path": .string(dir)]))
    }

    @Test func newBlankInsertDuplicateDeleteFrames() throws {
        let s = try session()
        let id = try newBlank(s)
        #expect(video(s, id) != nil)
        #expect(s.active?.doc.timeline != nil)
        let start = frames(s, id)
        try s.execute("layer.videoLayers.insertBlankFrame")
        #expect(frames(s, id) == start + 1)
        try s.execute("layer.videoLayers.duplicateFrame")
        #expect(frames(s, id) == start + 2)
        #expect(try s.execute("layer.videoLayers.deleteFrame")["frames"] == .int(start + 1))
        #expect(frames(s, id) == start + 1)
        #expect((s.active?.doc.timeline?.duration ?? 0) >= frames(s, id))
        #expect(s.undo())
        #expect(frames(s, id) == start + 2, "each frame edit is one history step")
    }

    @Test func rasterizeDropsTheStack() throws {
        let s = try session()
        try s.execute("layer.videoLayers.newBlankVideoLayer")
        #expect(try s.execute("layer.videoLayers.rasterize")["rasterized"] == true)
        let id = try #require(s.active?.activeLayer)
        #expect(video(s, id) == nil)
        guard case .raster? = s.active?.doc.layer(id)?.content else { Issue.record("not a raster"); return }
        #expect(!s.isEnabled("layer.rasterize.video"))
    }

    @Test func frameOpsNeedAVideoLayer() throws {
        let s = try session()
        #expect(throws: (any Error).self) { try s.execute("layer.videoLayers.insertBlankFrame") }
        #expect(s.disabledReason("layer.videoLayers.insertBlankFrame") == "select a video layer")
    }

    @Test func scrubKeepsContentARaster() throws {
        let s = try session()
        let id = try newBlank(s)
        try s.execute("layer.videoLayers.insertBlankFrame")
        try s.execute("timeline.setFrame", ["frame": 1])
        guard case .raster? = s.active?.doc.layer(id)?.content else { Issue.record("not a raster"); return }
    }

    /// #1288: a fill on a video frame survives scrubbing away and back.
    @Test func editsToAFrameSurviveScrubbing() throws {
        let s = try session()
        let id = try newBlank(s)
        try s.execute("layer.videoLayers.insertBlankFrame")
        try s.execute("timeline.setFrame", ["frame": 0])
        try fill(s, [1, 0, 0, 1])
        try s.execute("timeline.setFrame", ["frame": 1])
        #expect(try layerPixel(s, id)[3] < 0.01, "frame 1 stays blank")
        try s.execute("timeline.setFrame", ["frame": 0])
        let p = try layerPixel(s, id)
        #expect(p[0] > 0.99 && p[3] > 0.99, "frame 0 keeps its fill: \(p)")
        // Duplicate Frame copies the edited frame.
        try s.execute("layer.videoLayers.duplicateFrame")
        try s.execute("timeline.setFrame", ["frame": 1])
        #expect(try layerPixel(s, id)[0] > 0.99)
    }

    @Test func importedVideoRestoreFrameAndAllKeepSourcePixels() throws {
        let s = try session()
        let id = try footage(s, "original-footage")
        #expect(try layerPixel(s, id) == [1, 0, 0, 1])

        try s.execute("edit.fill", ["color": "#0000ff"])
        try s.execute("layer.videoLayers.restoreFrame")
        #expect(try layerPixel(s, id) == [1, 0, 0, 1], "current frame restores the red original")

        try s.execute("edit.fill", ["color": "#0000ff"])
        try s.execute("timeline.setFrame", ["frame": 1])
        try s.execute("edit.fill", ["color": "#0000ff"])
        try s.execute("layer.videoLayers.restoreAllFrames")
        #expect(try layerPixel(s, id) == [0, 1, 0, 1], "frame 1 restores green")
        try s.execute("timeline.setFrame", ["frame": 0])
        #expect(try layerPixel(s, id) == [1, 0, 0, 1], "frame 0 restores red")
        #expect(s.undo(), "restoration stays in history")
    }

    @Test func showAlteredVideoSwitchesBetweenOriginalAndEditedFrames() throws {
        let s = try session()
        let id = try footage(s, "show-altered-original")
        try s.execute("edit.fill", ["color": "#0000ff"])
        #expect(try layerPixel(s, id) == [0, 0, 1, 1])

        try s.execute("layer.videoLayers.showAlteredVideo")
        #expect(video(s, id)?.showAltered == false)
        #expect(try layerPixel(s, id) == [1, 0, 0, 1], "hidden altered footage shows red original")
        try s.execute("timeline.setFrame", ["frame": 1])
        #expect(try layerPixel(s, id) == [0, 1, 0, 1], "scrubbing while hidden shows green original")
        try s.execute("timeline.setFrame", ["frame": 0])
        try s.execute("layer.videoLayers.showAlteredVideo")
        #expect(try layerPixel(s, id) == [0, 0, 1, 1], "switching back reveals the blue edit")
    }

    @Test func restoringBlankVideoFramesStillProducesBlankFrames() throws {
        let s = try session()
        let id = try newBlank(s)
        try fill(s, [0, 0, 1, 1])
        try s.execute("layer.videoLayers.restoreFrame")
        #expect(try layerPixel(s, id)[3] == 0)
    }

    @Test func interpretFootageSetsTheLayerRate() throws {
        let s = try session()
        let id = try newBlank(s)
        try s.execute("layer.videoLayers.interpretFootage", ["fps": 12.0])
        #expect(video(s, id)?.fps == 12)
        try s.execute("layer.videoLayers.interpretFootage")
        #expect(video(s, id)?.fps == 12, "no fps leaves the rate alone")
    }

    // MARK: File footage

    func tmpdir(_ name: String) throws -> String {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("pc-video-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.path
    }

    func writePNG(_ path: String, _ w: Int, _ h: Int, _ color: String) throws {
        let s = Session()
        try s.execute("file.new", ["width": .int(w), "height": .int(h), "background": .string(color)])
        let doc = try #require(s.active).doc
        try Data(try EngineIO.export(doc, as: "png", services: s.services).bytes).write(to: URL(fileURLWithPath: path))
    }

    /// An animated GIF of solid `w`×`h` frames: one (colour, delay in centiseconds) each.
    func writeGIF(_ path: String, _ w: Int, _ h: Int, _ frames: [(SIMD3<UInt8>, UInt16)]) throws {
        let list = frames.map { WebCommands.Codec.GifFrame(indices: [UInt8](repeating: 0, count: w * h), palette: [$0.0], transparent: nil, delayCs: $0.1) }
        try Data(try WebCommands.Codec.encodeGifAnimated(w, h, list, loopForever: true)).write(to: URL(fileURLWithPath: path))
    }

    func layerOf(_ r: JSONValue) throws -> LayerId { LayerId(try #require(r["layer"]?.uint64Value)) }

    func frameRGB(_ s: Session, _ id: LayerId, _ frame: Int) -> [Float] {
        guard let v = video(s, id), frame < v.frames.count else { return [] }
        return Array(v.frames[frame].pixel(x: 1, y: 1).prefix(3))
    }

    @Test func newVideoLayerFromImageSequence() throws {
        let dir = try tmpdir("seq")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try writePNG("\(dir)/f01.png", 16, 12, "#ff0000")
        try writePNG("\(dir)/f02.png", 16, 12, "#00ff00")
        try writePNG("\(dir)/f03.png", 16, 12, "#0000ff")
        let s = try session()
        let r = try s.execute("layer.videoLayers.newVideoLayerFromFile", ["path": .string(dir)])
        #expect(r["frames"] == 3)
        let id = try layerOf(r)
        #expect(frames(s, id) == 3)
        #expect((s.active?.doc.timeline?.duration ?? 0) >= 3)
        #expect(frameRGB(s, id, 1) == [0, 1, 0], "sorted by name")
    }

    @Test func framesToLayersAndRenderVideo() throws {
        let dir = try tmpdir("ftl")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try writePNG("\(dir)/a.png", 10, 8, "#112233")
        try writePNG("\(dir)/b.png", 10, 8, "#445566")
        let s = try session()
        let r = try s.execute("file.import.videoFramesToLayers", ["path": .string(dir)])
        #expect(r["layers"] == 2)
        // Build a 2-frame video layer and render.
        let v = try s.execute("layer.videoLayers.newVideoLayerFromFile", ["path": .string(dir)])
        #expect(v["frames"] == 2)
        let out = try tmpdir("render")
        defer { try? FileManager.default.removeItem(atPath: out) }
        let rr = try s.execute("file.export.renderVideo", ["dir": .string(out), "format": "png"])
        #expect((rr["frames"]?.intValue ?? 0) >= 2)
        #expect(FileManager.default.fileExists(atPath: out))
    }

    @Test func renderVideoToAnimatedGif() throws {
        let dir = try tmpdir("gifsrc")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try writePNG("\(dir)/a.png", 10, 8, "#ff0000")
        try writePNG("\(dir)/b.png", 10, 8, "#00ff00")
        try writePNG("\(dir)/c.png", 10, 8, "#0000ff")
        let s = try session()
        try s.execute("layer.videoLayers.newVideoLayerFromFile", ["path": .string(dir)])
        let out = try tmpdir("gifout")
        defer { try? FileManager.default.removeItem(atPath: out) }
        let r = try s.execute("file.export.renderVideo", ["dir": .string(out), "format": "gif"])
        #expect(r["frames"] == 3)
        let gif = [UInt8](try Data(contentsOf: URL(fileURLWithPath: try #require(r["file"]?.stringValue))))
        #expect(Array(gif.prefix(6)) == Array("GIF89a".utf8))
        #expect(gif.filter { $0 == 0x2C }.count == 3, "3 frames")
    }

    @Test func animatedGifKeepsTransparency() throws {
        // #3061: a transparent document rendered as an animated GIF came out opaque black.
        let s = Session()
        try s.execute("file.new", ["width": 8, "height": 8, "background": "transparent"])
        try s.execute("timeline.create", ["duration": 2, "fps": 10])
        try s.execute("select.rect", ["x": 2, "y": 2, "width": 4, "height": 4])
        try s.execute("edit.fill", ["color": "#ff0000"])
        var gif: [UInt8] = []
        _ = try VideoCommands.renderVideoWith(s, ["format": "gif"], write: { _, bytes in gif = bytes }, progress: { _, _ in true })
        // Each frame has a transparent index and is cleared before the next (disposal 2).
        var packed: [UInt8] = []
        for i in 0..<max(gif.count - 3, 0) where gif[i] == 0x21 && gif[i + 1] == 0xF9 && gif[i + 2] == 0x04 { packed.append(gif[i + 3]) }
        #expect(packed == [0x09, 0x09])
        let doc = try EngineIO.importFile(name: "t.gif", bytes: gif, services: s.services).document
        let px = try s.services.renderer.render(doc, region: doc.bounds).px
        #expect(px[0].w == 0, "the corner stays transparent")
        #expect(px[3 * 8 + 3] == SIMD4(1, 0, 0, 1), "the square stays red")
    }

    @Test func aFullyTransparentAnimatedGifFrameEncodes() throws {
        let f = try VideoCommands.gifFrame([SIMD4<Float>](repeating: .zero, count: 4), 2, 5)
        #expect(f.transparent == UInt8(f.palette.count - 1))
        #expect(f.indices.allSatisfy { $0 == f.transparent })
    }

    /// Render Video picks up an edit made at the playhead without scrubbing first.
    @Test func editsToAFrameSurviveRender() throws {
        let s = try session()
        _ = try newBlank(s)
        try s.execute("layer.videoLayers.insertBlankFrame")
        try s.execute("timeline.setFrame", ["frame": 1])
        try s.execute("edit.fill", ["color": "#0000ff"])
        let out = try tmpdir("edited")
        defer { try? FileManager.default.removeItem(atPath: out) }
        try s.execute("file.export.renderVideo", ["dir": .string(out), "format": "png"])
        let name = try #require(s.active).doc.name
        let stem = name.lastIndex(of: ".").map { String(name[..<$0]) } ?? name
        let doc = try EngineIO.importPath("\(out)/\(stem)_0001.png", services: s.services).document
        let q = try s.services.renderer.compositeToSurface(doc, rect: doc.bounds, format: doc.pixelFormat).pixel(x: 2, y: 2)
        #expect(q[2] > 0.99 && q[0] < 0.01, "rendered frame 1 is blue: \(q)")
    }

    @Test func renderWriterProgressAndCancellationLeaveSessionUnchanged() throws {
        let s = try session()
        try s.execute("timeline.create", ["duration": 4, "fps": 4])
        let before = try #require(s.active).doc
        for format in ["png", "gif"] {
            var names: [String] = []
            var progress: [(Int, Int)] = []
            do {
                _ = try VideoCommands.renderVideoWith(s, ["format": .string(format)], write: { name, bytes in
                    #expect(!bytes.isEmpty)
                    names.append(name)
                }, progress: { done, total in
                    progress.append((done, total))
                    return done < 2
                })
                Issue.record("\(format): the render should stop")
            } catch {
                #expect("\(error)".contains("cancelled"), "\(error)")
            }
            #expect(names.count < 4)
            #expect(progress.first.map { $0 == (0, 4) } == true)
            #expect(progress.last.map { $0 == (2, 4) } == true, "\(progress)")
            #expect(s.active?.doc.timeline == before.timeline)
        }
    }

    /// A 16×12 32-bit Targa: red, alpha 255 on the left half and 0 on the right.
    func writeTGA(_ path: String) throws {
        var b: [UInt8] = [0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 16, 0, 12, 0, 32, 8]
        for _ in 0..<12 { for x in 0..<16 { b += [0, 0, 255, x < 8 ? 255 : 0] } }
        try Data(b).write(to: URL(fileURLWithPath: path))
    }

    /// #2225: an image sequence treats a frame's alpha as transparency, so TGA sequences keep
    /// their transparent areas.
    @Test func tgaSequenceFramesKeepTheirTransparency() throws {
        let dir = try tmpdir("tga")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try writeTGA("\(dir)/f01.tga")
        try writeTGA("\(dir)/f02.tga")
        let s = Session()
        let frames = try VideoCommands.loadFrames(s, dir, PixelFormat(mode: .rgb, sample: .u8, alpha: true)).frames
        #expect(frames.count == 2)
        for f in frames {
            #expect(f.pixel(x: 2, y: 6) == [1, 0, 0, 1])
            #expect(f.pixel(x: 12, y: 6)[3] == 0, "the right half stays transparent")
        }
    }

    @Test func anAnimatedGifBecomesAVideoLayerWithEveryFrame() throws {
        let dir = try tmpdir("gifin")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = "\(dir)/anim.gif"
        try writeGIF(path, 16, 12, [(SIMD3(255, 0, 0), 4), (SIMD3(0, 255, 0), 4), (SIMD3(0, 0, 255), 4)])
        let s = try session()
        let r = try s.execute("layer.videoLayers.newVideoLayerFromFile", ["path": .string(path)])
        #expect(r["frames"] == 3)
        let id = try layerOf(r)
        #expect(frames(s, id) == 3)
        #expect(frameRGB(s, id, 0) == [1, 0, 0])
        #expect(frameRGB(s, id, 1) == [0, 1, 0])
        #expect(frameRGB(s, id, 2) == [0, 0, 1])
        let doc = try #require(s.active).doc
        #expect(doc.timeline?.duration == 3)
        // 4 cs = 40 ms per frame: 25 fps, on the timeline and on the layer.
        #expect(doc.timeline?.fps == 25)
        #expect(video(s, id)?.fps == 25)
        // One history step: undo takes the layer back.
        #expect(s.undo())
        #expect(s.active?.doc.layer(id) == nil)
    }

    @Test func anExplicitFpsBeatsTheGifDelays() throws {
        let dir = try tmpdir("gifin-fps")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = "\(dir)/anim.gif"
        try writeGIF(path, 8, 8, [(SIMD3(255, 0, 0), 10), (SIMD3(0, 255, 0), 10)])
        let s = try session()
        let r = try s.execute("layer.videoLayers.newVideoLayerFromFile", ["path": .string(path), "fps": 12.0])
        #expect(video(s, try layerOf(r))?.fps == 12)
    }

    @Test func aStillGifIsOneFrameAtTheDefaultRate() throws {
        let dir = try tmpdir("gifin-still")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = "\(dir)/still.gif"
        try writeGIF(path, 8, 8, [(SIMD3(255, 0, 0), 0)])
        let s = try session()
        let r = try s.execute("layer.videoLayers.newVideoLayerFromFile", ["path": .string(path)])
        #expect(r["frames"] == 1)
        // A 0 delay is shown at 100 ms, so 10 fps.
        #expect(video(s, try layerOf(r))?.fps == 10)
    }

    @Test func videoFramesToLayersTakesEveryGifFrame() throws {
        let dir = try tmpdir("gifin-ftl")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = "\(dir)/anim.gif"
        try writeGIF(path, 8, 8, [(SIMD3(255, 0, 0), 5), (SIMD3(0, 255, 0), 5), (SIMD3(0, 0, 255), 5), (SIMD3(9, 9, 9), 5)])
        let s = try session()
        #expect(try s.execute("file.import.videoFramesToLayers", ["path": .string(path)])["layers"] == 4)
    }

    @Test func aGifRenderedByRenderVideoLoadsBackFrameForFrame() throws {
        let src = try tmpdir("gifrt-src")
        defer { try? FileManager.default.removeItem(atPath: src) }
        try writePNG("\(src)/a.png", 10, 8, "#ff0000")
        try writePNG("\(src)/b.png", 10, 8, "#0000ff")
        let s = try session()
        try s.execute("layer.videoLayers.newVideoLayerFromFile", ["path": .string(src), "fps": 20.0])
        let out = try tmpdir("gifrt-out")
        defer { try? FileManager.default.removeItem(atPath: out) }
        let r = try s.execute("file.export.renderVideo", ["dir": .string(out), "format": "gif"])
        let t = try session()
        let back = try t.execute("layer.videoLayers.newVideoLayerFromFile", ["path": try #require(r["file"])])
        #expect(back["frames"] == 2)
        let id = try layerOf(back)
        #expect(t.active?.doc.timeline?.fps == 20)
        // GIF palettes are 8-bit: the colours come back to within a quantization step.
        let (a, b) = (frameRGB(t, id, 0), frameRGB(t, id, 1))
        #expect(a.count == 3 && a[0] > 0.9 && a[2] < 0.1, "\(a)")
        #expect(b.count == 3 && b[2] > 0.9 && b[0] < 0.1, "\(b)")
    }

    @Test func aBrokenGifIsAnErrorNotACrash() throws {
        let dir = try tmpdir("gifin-bad")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = "\(dir)/bad.gif"
        try Data(Array("GIF89a".utf8) + [1, 0]).write(to: URL(fileURLWithPath: path))
        let s = try session()
        #expect(throws: (any Error).self) { try s.execute("layer.videoLayers.newVideoLayerFromFile", ["path": .string(path)]) }
    }

    @Test func gifDelaysMapToOneFrameRate() {
        // The most common delay wins; the first seen on a tie.
        #expect(VideoCommands.fpsFromDelays([40, 40, 100]) == 25)
        #expect(VideoCommands.fpsFromDelays([100, 40]) == 10)
        // Delays under 20 ms (0 and 10 are common) play at 100 ms, as in browsers.
        #expect(VideoCommands.fpsFromDelays([0, 10, 0]) == 10)
        #expect(VideoCommands.fpsFromDelays([]) == nil)
    }

    /// Not a photocraft test: Replace Footage and Reload Frame read the file again.
    @Test func replaceFootageAndReloadFrameReadTheFile() throws {
        let dir = try tmpdir("replace")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try writePNG("\(dir)/red.png", 16, 12, "#ff0000")
        try writePNG("\(dir)/blue.png", 16, 12, "#0000ff")
        let s = try session()
        let id = try layerOf(try s.execute("layer.videoLayers.newVideoLayerFromFile", ["path": .string("\(dir)/red.png")]))
        try s.execute("layer.videoLayers.replaceFootage", ["path": .string("\(dir)/blue.png")])
        #expect(frameRGB(s, id, 0) == [0, 0, 1])
        try writePNG("\(dir)/blue.png", 16, 12, "#00ff00")
        try s.execute("layer.videoLayers.reloadFrame")
        #expect(frameRGB(s, id, 0) == [0, 1, 0])
        #expect(throws: (any Error).self) { try s.execute("layer.videoLayers.replaceFootage") }
    }
}
