// Window › Timeline: a document-level playhead over a fixed number of frames at a frame rate, and
// the frame stacks of video layers.
// Port of photocraft-doc (crates/doc/src/video.rs), MIT OR Apache-2.0, © ArtCraft Team and the
// PhotoCraft contributors.
//
// Video layers (Layer › Video Layers) show their content for the current frame; `Timeline` is the
// shared clock. Frame-animation and video-timeline modes both reduce to "which frame is current".

import PCFoundation

/// Where a video layer's footage came from. JSON: `"Blank"` / `{"File":{"path":…}}`.
public enum VideoSource: Hashable, Sendable, Codable {
    /// Created blank (Layer › Video Layers › New Blank Video Layer).
    case blank
    /// Loaded from a file or image sequence.
    case file(path: String)

    private struct FilePayload: Codable { var path: String }

    public init(from decoder: any Decoder) throws {
        let v = try TaggedVariant(from: decoder)
        switch v.tag {
        case "Blank": self = .blank
        case "File": self = .file(path: try v.payload(FilePayload.self).path)
        default: throw v.unknown()
        }
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .blank: try Tagged.unit("Blank", to: encoder)
        case .file(let path): try Tagged.variant("File", FilePayload(path: path), to: encoder)
        }
    }
}

/// A video layer's frame stack (Layer › Video Layers). The layer's displayed content surface is a
/// cache of `frames[timeline.current]`, which the engine keeps in sync as the playhead moves.
///
/// Frames are full raster surfaces held in memory and saved in native documents. The optional
/// original footage is kept separately from painted frames for comparison/restore; copy-on-write
/// surfaces share unchanged pixel tiles with edited frames.
public struct VideoData: Sendable {
    public var frames: [Surface]
    /// Immutable original footage of a file-backed sequence (nil for blank video layers).
    public var originalFrames: [Surface]?
    public var source: VideoSource
    public var fps: Float
    /// Show the altered (painted) frames rather than the original footage.
    public var showAltered: Bool

    public init(frames: [Surface], fps: Float) {
        self.frames = frames
        originalFrames = nil
        source = .blank
        self.fps = fps
        showAltered = true
    }

    public var count: Int { frames.count }
    public var isEmpty: Bool { frames.isEmpty }
}

extension VideoData: Equatable {
    /// Compares the stack by shape, not pixel contents (enough for change detection), as
    /// photocraft does.
    public static func == (a: VideoData, b: VideoData) -> Bool {
        a.frames.count == b.frames.count
            && a.originalFrames?.count == b.originalFrames?.count
            && a.source == b.source
            && a.fps == b.fps
            && a.showAltered == b.showAltered
    }
}

/// The document timeline.
public struct Timeline: Hashable, Sendable, Codable {
    /// Frames per second.
    public var fps: Float
    /// Total number of frames (>= 1).
    public var duration: Int
    /// The playhead (0-based frame index).
    public var current: Int
    /// Work-area start frame (inclusive).
    public var workStart: Int
    /// Work-area end frame (exclusive).
    public var workEnd: Int

    public init(fps: Float, duration: Int, current: Int, workStart: Int, workEnd: Int) {
        self.fps = fps; self.duration = duration; self.current = current; self.workStart = workStart; self.workEnd = workEnd
    }

    public init(duration: Int, fps: Float) {
        let d = max(duration, 1)
        self.init(fps: Timeline.validFPS(fps), duration: d, current: 0, workStart: 0, workEnd: d)
    }

    /// Keep every index inside `0..<duration` and the work area non-empty.
    public mutating func clamp() {
        duration = max(duration, 1)
        fps = Timeline.validFPS(fps)
        current = min(max(current, 0), duration - 1)
        workStart = min(max(workStart, 0), duration - 1)
        workEnd = min(max(workEnd, workStart + 1), duration)
    }

    /// Move the playhead `delta` frames, stopping at the first and last frame. Saturating, so it's
    /// safe on any stored timeline, even one loaded with `duration` 0 or `Int.max`.
    public mutating func step(_ delta: Int64) {
        let n = Int(clamping: delta.magnitude)
        let moved = delta < 0 ? max(current - n, 0) : (current.addingReportingOverflow(n).overflow ? Int.max : current + n)
        current = min(moved, max(duration - 1, 0))
    }

    /// Playhead time in seconds.
    public var time: Float { Float(current) / max(fps, 1e-3) }

    /// A usable frame rate: positive and finite, else the 30 fps default.
    static func validFPS(_ fps: Float) -> Float { fps.isFinite && fps > 0 ? fps : 30 }

    enum CodingKeys: String, CodingKey { case fps, duration, current, workStart = "work_start", workEnd = "work_end" }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fps = try c.decode(Float.self, forKey: .fps)
        duration = try c.decode(Int.self, forKey: .duration)
        current = try c.decode(Int.self, forKey: .current)
        workStart = try c.decode(.workStart, or: 0)
        workEnd = try c.decode(Int.self, forKey: .workEnd)
    }
}
