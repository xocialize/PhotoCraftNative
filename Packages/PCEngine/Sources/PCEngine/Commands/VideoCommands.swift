// Port of photocraft-engine (crates/engine/src/video_cmds.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Layer › Video Layers (and Rasterize › Video). A video layer holds a stack of frames; the layer's
// displayed raster content is the frame at the timeline playhead, kept in sync by `sync` after
// any edit or navigation. Paint, fills and filters edit that displayed content, so `store` writes
// it back into the playhead's frame before anything re-syncs. The frame-stack edits are model
// edits and run here; loading footage (files, image sequences, animated GIFs) and Render Video
// are `VideoCommands+Footage.swift`.

import Foundation
import PCDocument
import PCFoundation

public enum VideoCommands: CommandModule {
    public static let name = "video_cmds"
    static let m = name

    // MARK: Frame sync

    /// Sets every video layer's displayed content to its frame at the playhead.
    static func sync(_ doc: inout Document) {
        let cur = doc.timeline?.current ?? 0
        doc.forEachLayerMut { l in
            guard let v = l.video else { return }
            let visible = v.showAltered ? v.frames : (v.originalFrames ?? v.frames)
            guard !visible.isEmpty else { return }
            let f = visible[min(max(cur, 0), visible.count - 1)]
            l.withRaster { $0 = f }
        }
    }

    /// Keeps edits made to every video layer's displayed content (paint, fills, filters) by
    /// writing it back into its frame at the playhead. Call before moving the playhead or
    /// re-syncing.
    static func store(_ doc: inout Document) {
        let cur = doc.timeline?.current ?? 0
        doc.forEachLayerMut { l in
            guard var v = l.video, case .raster(let s) = l.content else { return }
            let at = min(max(cur, 0), max(v.frames.count - 1, 0))
            // When showing the original, the layer's displayed surface is a preview, not an edit
            // to write over the altered frame (#3060).
            if (v.showAltered || v.originalFrames == nil) && at < v.frames.count {
                v.frames[at] = s
                l.video = v
            }
        }
    }

    // MARK: Enablement

    /// The active layer, if it's a video layer.
    static let activeVideo: CommandEnabled = { s, _ in
        guard let st = s.active else { return "no document" }
        guard let id = st.activeLayer, let l = st.doc.layer(id), l.video != nil else { return "select a video layer" }
        return nil
    }

    static let hasDoc: CommandEnabled = { s, _ in s.active == nil ? "no document" : nil }

    // MARK: Edits

    /// Edits the active video layer's `VideoData` at the playhead, then re-syncs the displayed
    /// frame.
    static func editVideo(_ s: Session, _ label: String, _ f: @escaping (inout VideoData, Int) throws -> Void) throws -> JSONValue {
        let count = try s.edit(label) { doc, active -> Int in
            store(&doc)
            let cur = doc.timeline?.current ?? 0
            guard let id = active else { throw EngineError.noDocument }
            guard doc.layer(id) != nil else { throw EngineError.noLayer(id) }
            let n = try doc.updateLayer(id) { l -> Int in
                guard var v = l.video else { throw EngineError.bad(label, "the active layer is not a video layer") }
                try f(&v, cur)
                l.video = v
                return v.frames.count
            } ?? 0
            if var t = doc.timeline {
                t.duration = max(t.duration, max(n, 1))
                t.workEnd = max(t.workEnd, t.duration)
                t.clamp()
                doc.timeline = t
            }
            sync(&doc)
            return n
        }
        return ["frames": .int(count)]
    }

    static func blank(_ fmt: PixelFormat) -> Surface { Surface(format: fmt) }

    static func newBlank(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let id = try s.edit("New Blank Video Layer") { doc, active -> LayerId in
            store(&doc)
            let fmt = doc.pixelFormat
            if doc.timeline == nil { doc.timeline = Timeline(duration: 1, fps: 30) }
            let fps = doc.timeline?.fps ?? 30
            let n = max(doc.timeline?.duration ?? 1, 1)
            let frames = (0..<n).map { _ in Surface(format: fmt) }
            var l = Layer.raster(doc.nextLayerName("Video Layer"), format: fmt)
            l.video = VideoData(frames: frames, fps: fps)
            let id = doc.insertAbove(active, l)
            active = id
            sync(&doc)
            return id
        }
        return ["layer": .id(id)]
    }

    static func insertBlank(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        guard let fmt = s.active?.doc.pixelFormat else { throw EngineError.noDocument }
        return try editVideo(s, "Insert Blank Frame") { v, cur in
            let at = min(cur + 1, v.frames.count)
            v.frames.insert(blank(fmt), at: max(at, 0))
            if var original = v.originalFrames {
                // The stacks stay aligned, but never index past a shorter one.
                original.insert(blank(fmt), at: max(min(at, original.count), 0))
                v.originalFrames = original
            }
        }
    }

    static func duplicateFrame(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        try editVideo(s, "Duplicate Frame") { v, cur in
            guard cur >= 0, cur < v.frames.count else { return }
            let f = v.frames[cur]
            if var original = v.originalFrames {
                let orig = cur < original.count ? original[cur] : blank(f.format)
                original.insert(orig, at: min(cur + 1, original.count))
                v.originalFrames = original
            }
            v.frames.insert(f, at: cur + 1)
        }
    }

    static func deleteFrame(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        try editVideo(s, "Delete Frame") { v, cur in
            guard v.frames.count > 1, cur >= 0, cur < v.frames.count else { return }
            v.frames.remove(at: cur)
            if var original = v.originalFrames, cur < original.count {
                original.remove(at: cur)
                v.originalFrames = original
            }
        }
    }

    static func restoreFrame(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        guard let fmt = s.active?.doc.pixelFormat else { throw EngineError.noDocument }
        return try editVideo(s, "Restore Frame") { v, cur in
            guard cur >= 0, cur < v.frames.count else { return }
            let original = v.originalFrames.flatMap { cur < $0.count ? $0[cur] : nil }
            v.frames[cur] = original ?? blank(fmt)
        }
    }

    static func restoreAll(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        guard let fmt = s.active?.doc.pixelFormat else { throw EngineError.noDocument }
        return try editVideo(s, "Restore All Frames") { v, _ in
            for i in v.frames.indices {
                v.frames[i] = v.originalFrames.flatMap { i < $0.count ? $0[i] : nil } ?? blank(fmt)
            }
        }
    }

    static func showAltered(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        try editVideo(s, "Show Altered Video") { v, _ in v.showAltered.toggle() }
    }

    /// Rasterize: drop the frame stack, keeping the current frame as a normal pixel layer.
    static func rasterize(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        try s.edit("Rasterize Video") { doc, active in
            guard let id = active else { throw EngineError.noDocument }
            // The content already shows the current frame (kept in sync); just drop the stack.
            guard doc.updateLayer(id, { $0.video = nil }) != nil else { throw EngineError.noLayer(id) }
        }
        return ["rasterized": true]
    }

    static func interpretFootage(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let fps = p["fps"]?.doubleValue
        return try editVideo(s, "Interpret Footage") { v, _ in
            if let f = fps { v.fps = Float(f) }
        }
    }

    // MARK: Registration

    public static func register(into r: inout CommandRegistry) {
        let vl = ["Layer", "Video Layers"]
        let none = "{} → {}"
        r.add([
            CommandSpec("layer.videoLayers.newBlankVideoLayer", "New Blank Video Layer", menu: vl, params: none, module: m, enabled: hasDoc, run: newBlank),
            CommandSpec("layer.videoLayers.insertBlankFrame", "Insert Blank Frame", menu: vl, params: none, module: m, enabled: activeVideo, run: insertBlank),
            CommandSpec("layer.videoLayers.duplicateFrame", "Duplicate Frame", menu: vl, params: none, module: m, enabled: activeVideo, run: duplicateFrame),
            CommandSpec("layer.videoLayers.deleteFrame", "Delete Frame", menu: vl, params: none, module: m, enabled: activeVideo, run: deleteFrame),
            CommandSpec("layer.videoLayers.restoreFrame", "Restore Frame", menu: vl, params: none, module: m, enabled: activeVideo, run: restoreFrame),
            CommandSpec("layer.videoLayers.restoreAllFrames", "Restore All Frames", menu: vl, params: none, module: m, enabled: activeVideo, run: restoreAll),
            CommandSpec("layer.videoLayers.showAlteredVideo", "Show Altered Video", menu: vl, params: none, module: m, enabled: activeVideo, run: showAltered),
            CommandSpec("layer.videoLayers.rasterize", "Rasterize", menu: vl, params: none, module: m, enabled: activeVideo, run: rasterize),
            CommandSpec("layer.rasterize.video", "Video", menu: ["Layer", "Rasterize"], params: none, module: m, enabled: activeVideo, run: rasterize),
            CommandSpec("layer.videoLayers.newVideoLayerFromFile", "New Video Layer from File…", menu: vl, params: none, module: m, enabled: hasDoc,
                        run: newFromFile),
            CommandSpec("layer.videoLayers.replaceFootage", "Replace Footage…", menu: vl, params: none, module: m, enabled: activeVideo, run: replaceFootage),
            CommandSpec("layer.videoLayers.interpretFootage", "Interpret Footage…", menu: vl, params: none, module: m, enabled: activeVideo, run: interpretFootage),
            CommandSpec("layer.videoLayers.reloadFrame", "Reload Frame", menu: vl, params: none, module: m, enabled: activeVideo, run: reloadFrame),
            CommandSpec("file.import.videoFramesToLayers", "Video Frames to Layers…", menu: ["File", "Import"], params: none, module: m, enabled: hasDoc,
                        run: framesToLayers),
            CommandSpec("file.export.renderVideo", "Render Video…", menu: ["File", "Export"], params: none, module: m, enabled: hasDoc, run: renderVideo),
        ])
    }
}
