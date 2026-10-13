// Port of photocraft-engine (crates/engine/src/video_cmds.rs: file-based footage — `Footage`, `fps_from_delays`, `load_frames`, `new_from_file`, `replace_footage`, `reload_frame`, `frames_to_layers`, `render_video`, `render_video_with`, `gif_frame`; with photocraft-io flat.rs `tga_alpha_channel_to_transparency`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Footage comes from a single image (one frame, or every frame of an animated GIF) or a folder of
// images (sorted: an image sequence), each flattened into a full raster frame in the document's
// format. Files are read through the session's file service and imported by PCIO; animated GIF
// frames and their delays come from PCPlatform's codecs. Render Video composites every timeline
// frame and writes an image sequence through PCIO's exporters, or one animated GIF (each frame
// quantised to its own palette, our GIF writer in `WebCommands+Codecs.swift`).

import Foundation
import PCAlgo
import PCDocument
import PCFoundation
import PCPlatform

extension VideoCommands {
    /// Frames loaded from a file or an image sequence.
    struct Footage {
        var frames: [Surface]
        /// The frame rate the footage itself implies (a single animated GIF's delays); nil for
        /// stills and sequences, which carry none.
        var fps: Float?
    }

    /// The frame rate for a GIF's frame delays (milliseconds): that of the most common delay, the
    /// first one seen on a tie. Delays under 20 ms (which includes the 0 and 10 ms many encoders
    /// write) are shown at 100 ms, as browsers do.
    static func fpsFromDelays(_ delays: [UInt32]) -> Float? {
        var counts: [(UInt32, Int)] = []
        for d0 in delays {
            let d = d0 < 20 ? 100 : d0
            if let i = counts.firstIndex(where: { $0.0 == d }) { counts[i].1 += 1 } else { counts.append((d, 1)) }
        }
        var best: (UInt32, Int)?
        for c in counts where best == nil || c.1 > best?.1 ?? 0 { best = c }
        return best.map { 1000 / Float($0.0) }
    }

    static let footageExtensions: Set<String> = ["png", "jpg", "jpeg", "tif", "tiff", "webp", "bmp", "gif", "tga", "exr", "pcraft", "psd"]

    /// A Targa's alpha opens as a channel (as in Photoshop); a frame's alpha is transparency
    /// (photocraft-io `tga_alpha_channel_to_transparency`). A no-op unless the document is one
    /// layer with alpha plus one non-spot channel.
    static func tgaAlphaChannelToTransparency(_ doc: inout Document) {
        guard doc.layers.count == 1, doc.channels.count == 1, doc.channels[0].spot == nil, case .raster(var s) = doc.layers[0].content else { return }
        let ch = s.format.channels
        guard s.format.alpha, ch >= 2 else { return }
        let canvas = doc.bounds
        var px = s.readRegion(canvas)
        let a = doc.channels[0].surface.readRegion(canvas)
        var i = 0
        while (i + 1) * ch <= px.count && i < a.count {
            px[(i + 1) * ch - 1] = a[i]
            i += 1
        }
        s.writeRegion(canvas, px)
        s.prune()
        doc.layers[0].content = .raster(s)
        doc.layers[0].name = "Layer 0"
        doc.layers[0].locks.transparency = false
        doc.layers[0].locks.position = false
        doc.channels.removeAll()
    }

    /// Loads frames from `path`: a single image (1 frame, or every frame of an animated GIF), or
    /// a folder of images (sorted = an image sequence). Each becomes a full raster frame in `fmt`.
    static func loadFrames(_ s: Session, _ path: String, _ fmt: PixelFormat) throws -> Footage {
        let fs = s.services.fileSystem
        let files: [String]
        if fs.isDirectory(path) {
            let names: [String]
            do { names = try fs.list(path) } catch { throw EngineError.other("read dir `\(path)`: \(EngineError.wrap(error))") }
            files = names.map { FileCommands.join(path, $0) }
                .filter { p in !fs.isDirectory(p) && EngineIO.fileExtension(p).map(footageExtensions.contains) == true }
                .sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
        } else {
            files = [path]
        }
        if files.isEmpty { throw EngineError.other("no images in `\(path)`") }
        var frames: [Surface] = []
        frames.reserveCapacity(files.count)
        var delays: [UInt32] = []
        for f in files {
            let data: Data
            do { data = try fs.read(f) } catch { throw EngineError.other("read `\(f)`: \(EngineError.wrap(error))") }
            if ImageFormat.detect(data) == .gif {
                do {
                    let info = try ImageCodecs.frames(data)
                    if info.isEmpty { throw EngineError.other("not a readable GIF (no frames)") }
                    for fr in info {
                        var o = DecodeOptions()
                        o.frame = fr.index
                        let img = try ImageCodecs.decode(data, options: o)
                        var doc = Document(name: FileCommands.fileName(f), size: img.size, mode: .rgb, depth: .u8)
                        doc.layers = [Layer.raster("Layer 0", surface: img.surface.convertedAny(to: doc.pixelFormat))]
                        frames.append(try FileCommands.flattened(s, doc, fmt))
                        delays.append(UInt32(min(max(((fr.delay ?? 0) * 1000).rounded(), 0), Double(UInt32.max))))
                    }
                } catch {
                    throw EngineError.other("`\(f)`: \(EngineError.wrap(error))")
                }
                continue
            }
            var doc = try FileCommands.import(s, f, [UInt8](data))
            // A Targa's alpha opens as a channel (as in Photoshop); a frame's alpha is transparency.
            if EngineIO.fileExtension(f) == "tga" { tgaAlphaChannelToTransparency(&doc) }
            frames.append(try FileCommands.flattened(s, doc, fmt))
        }
        // Only a lone GIF says how fast it plays; a sequence mixing files has no single rate.
        return Footage(frames: frames, fps: files.count == 1 ? fpsFromDelays(delays) : nil)
    }

    static func pathParam(_ p: JSONValue, _ cmd: String) throws -> String {
        guard let path = p["path"]?.stringValue else { throw EngineError.bad(cmd, "need `path`") }
        return path
    }

    static func newFromFile(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let path = try pathParam(p, "layer.videoLayers.newVideoLayerFromFile")
        guard let fmt = s.active?.doc.pixelFormat else { throw EngineError.noDocument }
        let footage = try loadFrames(s, path, fmt)
        // An explicit `fps` wins, then the rate the footage implies, then 30.
        let fps = p["fps"]?.doubleValue.map { Float($0) } ?? footage.fps ?? 30
        let n = footage.frames.count
        let id = try s.edit("New Video Layer from File") { doc, active -> LayerId in
            store(&doc)
            if var t = doc.timeline {
                t.duration = max(t.duration, n)
                t.clamp()
                doc.timeline = t
            } else {
                doc.timeline = Timeline(duration: n, fps: fps)
            }
            var trimmed = Substring(path)
            while trimmed.count > 1 && (trimmed.hasSuffix("/") || trimmed.hasSuffix("\\")) { trimmed = trimmed.dropLast() }
            let base = FileCommands.stem(String(trimmed))
            let name = doc.nextLayerName(base.isEmpty ? "Video" : base)
            var l = Layer.raster(name, format: fmt)
            var v = VideoData(frames: footage.frames, fps: fps)
            v.originalFrames = v.frames
            v.source = .file(path: path)
            l.video = v
            let id = doc.insertAbove(active, l)
            active = id
            sync(&doc)
            return id
        }
        return ["layer": .id(id), "frames": .int(n)]
    }

    static func replaceFootage(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let path = try pathParam(p, "layer.videoLayers.replaceFootage")
        guard let fmt = s.active?.doc.pixelFormat else { throw EngineError.noDocument }
        let frames = try loadFrames(s, path, fmt).frames
        return try editVideo(s, "Replace Footage") { v, _ in
            v.originalFrames = frames
            v.frames = frames
            v.source = .file(path: path)
        }
    }

    static func reloadFrame(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        // Reload the whole stack from its file source (what a frame reload needs for a sequence).
        let cmd = "layer.videoLayers.reloadFrame"
        guard let st = s.active, let id = st.activeLayer else { throw EngineError.noDocument }
        guard let v = st.doc.layer(id)?.video else { throw EngineError.bad(cmd, "not a video layer") }
        guard case .file(let path) = v.source else { throw EngineError.bad(cmd, "this layer has no file source to reload") }
        let frames = try loadFrames(s, path, st.doc.pixelFormat).frames
        return try editVideo(s, "Reload Frame") { v, _ in
            v.originalFrames = frames
            v.frames = frames
        }
    }

    /// Import › Video Frames to Layers: every frame of a file or sequence as its own layer.
    static func framesToLayers(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let path = try pathParam(p, "file.import.videoFramesToLayers")
        guard let fmt = s.active?.doc.pixelFormat else { throw EngineError.noDocument }
        let frames = try loadFrames(s, path, fmt).frames
        let n = frames.count
        try s.edit("Video Frames to Layers") { doc, active in
            var above = active
            for (i, f) in frames.enumerated() {
                var l = Layer.raster("Frame \(i + 1)", format: fmt)
                l.content = .raster(f)
                above = doc.insertAbove(above, l)
            }
            active = above
        }
        return ["layers": .int(n)]
    }

    /// Export › Render Video: composite the whole document at each timeline frame and write an
    /// image sequence (`{dir}/{stem}_NNNN.{format}`) or one animated GIF.
    static func renderVideo(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        guard let dir = p["dir"]?.stringValue else { throw EngineError.bad("file.export.renderVideo", "need `dir`") }
        do { try s.services.fileSystem.createDirectory(dir) } catch { throw EngineError.other("mkdir `\(dir)`: \(EngineError.wrap(error))") }
        return try renderVideoWith(s, p, write: { name, bytes in try FileCommands.writeFile(s, "\(dir)/\(name)", bytes) }, progress: { _, _ in true })
    }

    /// Render through a caller-owned writer, which receives one filename at a time (never an
    /// ambient directory). Returning false from `progress` stops at a frame boundary; the caller
    /// owns cleanup.
    public static func renderVideoWith(_ s: Session, _ p: JSONValue, write: (String, [UInt8]) throws -> Void,
                                       progress: (Int, Int) -> Bool) throws -> JSONValue {
        let dir = p["dir"]?.stringValue ?? ""
        let format = p["format"]?.stringValue ?? "png"
        guard let st = s.active else { throw EngineError.noDocument }
        var base = st.doc
        store(&base)
        let frames = max(base.timeline?.duration ?? 1, 1)
        let fps = max(base.timeline?.fps ?? 30, 1)
        let stem = base.name.lastIndex(of: ".").map { String(base.name[..<$0]) } ?? base.name
        let fmt = base.pixelFormat
        let bounds = base.bounds
        let (w, h) = (bounds.width, bounds.height)
        let cancelled = EngineError.other("render cancelled")
        if !progress(0, frames) { throw cancelled }
        func frameDoc(_ f: Int) -> Document {
            var doc = base
            if var t = doc.timeline {
                t.current = f
                doc.timeline = t
            }
            sync(&doc)
            return doc
        }
        // Animated GIF: one file, every frame quantised to its own palette.
        if format.lowercased() == "gif" {
            let delay = UInt16(min(max((100 / fps).rounded(), 1), 65535))
            var gframes: [WebCommands.Codec.GifFrame] = []
            gframes.reserveCapacity(frames)
            for f in 0..<frames {
                let surf = try FileCommands.flattened(s, frameDoc(f), fmt)
                gframes.append(try gifFrame(surf.readRGBA(bounds), w, delay))
                // The final report follows encoding/writing, so total means the output exists.
                if !progress(min(f + 1, max(frames - 1, 0)), frames) { throw cancelled }
            }
            let gif: [UInt8]
            do { gif = try WebCommands.Codec.encodeGifAnimated(w, h, gframes, loopForever: true) } catch { throw EngineError.other("\(error)") }
            let name = "\(stem).gif"
            try write(name, gif)
            if !progress(frames, frames) { throw cancelled }
            return ["frames": .int(frames), "file": .string("\(dir)/\(name)")]
        }
        // Image sequence.
        var files: [String] = []
        for f in 0..<frames {
            let path = "\(stem)_\(String(format: "%04d", f)).\(format)"
            let bytes: [UInt8]
            do { bytes = try EngineIO.export(frameDoc(f), as: format, services: s.services).bytes } catch {
                throw EngineError.other("render frame \(f): \(EngineError.wrap(error))")
            }
            try write(path, bytes)
            files.append(path)
            if !progress(f + 1, frames) { throw cancelled }
        }
        return ["frames": .int(files.count), "dir": .string(dir)]
    }

    /// One animated GIF frame from straight RGBA pixels, as Save for Web's GIF does: pixels under
    /// 50 % opacity get the frame's transparent index, the rest are drawn opaque, and the palette
    /// is built from the visible pixels with one entry kept for transparency.
    static func gifFrame(_ px0: [SIMD4<Float>], _ w: Int, _ delayCs: UInt16) throws -> WebCommands.Codec.GifFrame {
        var px = px0
        let transparent = px.contains { $0.w < 0.5 }
        let visible = px.filter { $0.w >= 0.5 }.map { SIMD4($0.x, $0.y, $0.z, 1) }
        // A fully transparent frame still needs a palette.
        var pal: [SIMD3<UInt8>]
        do { pal = try Quantize.buildPalette(visible.isEmpty ? px : visible, kind: .adaptive, colors: transparent ? 255 : 256, forced: .none) } catch {
            throw EngineError.other("\(error)")
        }
        var t: Int?
        if transparent {
            if pal.count > 255 { pal.removeLast(pal.count - 255) }
            pal.append(pal.first ?? .zero)
            t = pal.count - 1
        }
        if pal.isEmpty { pal = [.zero] }
        let indices = Quantize.quantize(&px, w: w, palette: pal, dither: .none, amount: 1, transparent: t)
        return WebCommands.Codec.GifFrame(indices: indices, palette: pal, transparent: t.map { UInt8($0) }, delayCs: delayCs)
    }
}
