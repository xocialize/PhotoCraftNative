// Port of photocraft-engine (crates/engine/src/brush_cmds.rs `LiveStroke`, `LiveCommit`; lib.rs `offer_live_stroke`, `clear_live_stroke`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// The live Brush/Pencil stroke: a `paint.stroke` / `paint.pencil` rendered while it is drawn,
// onto a copy of the active document, so the canvas shows the real dabs (smoothing tail and
// symmetry mirrors included) before the stroke commits. Committing the same params and points
// with `"seed": live.seed` gives the same pixels; offering the finished live stroke to the session
// lets that commit take its pixels instead of rendering the stroke again.

import PCDocument
import PCFoundation
import PCPaint

extension BrushCommands {
    /// The finished live stroke offered to its own commit (photocraft `Session::live_commit`).
    enum LiveCommitKey: StateKey { static let defaultValue: BrushCommands.LiveCommit? = nil }

    /// A finished live stroke offered to its own commit (`offerLiveStroke`): when the committing
    /// `paint.stroke` / `paint.pencil` matches it (same command, document revision, params, seed
    /// and points), the command takes these pixels instead of rendering the stroke again.
    public struct LiveCommit: Sendable {
        let cmd: String
        let base: (DocId, UInt64)
        let params: JSONValue
        let seed: UInt64
        let points: [StrokePoint]
        let surface: Surface
        let bounds: PixelRect

        /// The params that decide the pixels, without the points and seed (compared separately).
        static func settings(_ p: JSONValue) -> JSONValue {
            guard case .object(var o) = p else { return p }
            o["points"] = nil
            o["seed"] = nil
            return .object(o)
        }

        func matches(_ s: Session, _ cmd: String, _ p: JSONValue, _ pts: [StrokePoint]) -> Bool {
            guard let st = s.active else { return false }
            return self.cmd == cmd && st.doc.id == base.0 && st.revision == base.1 && p["seed"]?.uint64Value == seed
                && points == pts && LiveCommit.settings(p) == LiveCommit.settings(params)
        }
    }

    /// Offer a finished live stroke to the `paint.stroke` / `paint.pencil` that commits it
    /// (photocraft `Session::offer_live_stroke`).
    public static func offerLiveStroke(_ s: Session, _ live: LiveStroke) throws {
        s.state[LiveCommitKey.self] = try live.intoCommit()
    }

    /// Withdraw an offer the command didn't take.
    public static func clearLiveStroke(_ s: Session) {
        s.state[LiveCommitKey.self] = nil
    }

    /// A `paint.stroke` rendered while it is drawn, onto a copy of the active document.
    public struct LiveStroke: Sendable {
        /// The active document with the stroke so far.
        public private(set) var doc: Document
        /// Jitter seed to pass to `paint.stroke`.
        public let seed: UInt64
        let cmd: String
        var renderer: StrokeRenderer
        let symmetry: SymmetryCommands.PaintingSymmetry?
        var mirrors: [StrokeRenderer]
        var mirrorDistinct: [Bool]
        /// What the symmetric preview drew last, once a mirror differs from the stroke, and how
        /// many passes it merged (a mirror joining redraws every tile).
        var unionLive: (UnionLive, Int)?
        let pre: Surface
        let sel: Surface?
        let lock: Bool
        let layer: LayerId?
        let params: JSONValue
        /// Where the doc shows the stroke's end as finishing it would draw it (see `push`).
        var tail: PixelRect = .empty
        /// Every point rendered so far, in order.
        var points: [StrokePoint] = []
        /// The document and revision the stroke started on.
        let base: (DocId, UInt64)
        /// The document's own CMYK profile, entered for every push (photocraft's `cmyk`).
        var cmyk: (any CMYKConverter)?

        static let placeholder = Document(name: "", size: PixelSize(width: 0, height: 0), mode: .rgb, depth: .u8)

        /// Start from `paint.stroke` params; their `points` are rendered.
        public static func begin(_ s: Session, _ p: JSONValue) throws -> LiveStroke {
            try beginWith(s, "paint.stroke", p)
        }

        /// Start a live stroke of `cmd`: `paint.stroke` (the Brush and Eraser) or `paint.pencil`.
        public static func beginWith(_ s: Session, _ cmd: String, _ p: JSONValue) throws -> LiveStroke {
            if let why = hasPaintable(s, p) { throw EngineError.other(why) }
            let pts = try parsePoints(p, cmd)
            let pencil: Bool
            switch cmd {
            case "paint.stroke": pencil = false
            case "paint.pencil": pencil = true
            default: throw bad(cmd, "live strokes are `paint.stroke` or `paint.pencil`")
            }
            var brush0 = pencil ? try pencilBrush(s, p) : withBlendMode(try resolveBrush(s, p, cmd), p)
            // JSON numbers are doubles in this engine: a seed derived from the points keeps 53 bits,
            // so the commit's `"seed": live.seed` gives exactly this stroke.
            if p["seed"]?.uint64Value == nil { brush0.seed &= seedMask }
            let (seed, fg) = (brush0.seed, brush0.color)
            let (layer, brush1, zoom) = try strokeTarget(s, p, brush0)
            var brush = brush1
            guard let st = s.active else { throw EngineError.noDocument }
            let base = (st.doc.id, st.revision)
            var doc = st.doc
            let sel = doc.selection
            let bg = s.tools.background
            let autoErase = pencil && flag(p, "autoErase", false)
            let (pre, lock) = try Channels.withTargetSurface(&doc, layer: layer, p) { surf, lock -> (Surface, Bool) in
                eraseLocked(&brush, lock, bg)
                if autoErase { applyAutoErase(&brush, surf, pts.first, fg, bg) }
                return (surf, lock)
            }
            let renderer = StrokeRenderer(brush, format: pre.format, zoom: zoom)
            let symmetry = st.view[SymmetryCommands.Key.self]
            let n = symmetry?.mirrorCount ?? 0
            let mirrors = (0..<n).map { _ in StrokeRenderer(brush, format: pre.format, zoom: zoom) }
            var live = LiveStroke(doc: doc, seed: seed, cmd: cmd, renderer: renderer, symmetry: symmetry, mirrors: mirrors,
                                  mirrorDistinct: [Bool](repeating: false, count: n), unionLive: nil, pre: pre, sel: sel, lock: lock,
                                  layer: layer, params: p, base: base, cmyk: DocumentCMYK.converter(for: doc))
            _ = try live.push(pts)
            return live
        }

        /// The stroke as its commit would take it over (see `LiveCommit`).
        public func intoCommit() throws -> LiveCommit {
            let b = bounds
            var d = doc
            let surf = try Channels.withTargetSurface(&d, layer: layer, params) { s, _ in s }
            return LiveCommit(cmd: cmd, base: base, params: params, seed: seed, points: points, surface: surf, bounds: b)
        }

        /// Everything the stroke has touched so far.
        public var bounds: PixelRect {
            var b = renderer.bounds.union(tail)
            for (r, distinct) in zip(mirrors, mirrorDistinct) where distinct { b = b.union(r.bounds) }
            return b
        }

        /// `(brush, pointer)` document positions while smoothing holds the brush back from the
        /// pointer: the canvas draws a line between them.
        public var smoothingString: (brush: SIMD2<Double>, pointer: SIMD2<Double>)? { renderer.smoothingString }

        /// Does the stroke change with time while the pointer is held still (airbrush Build-up,
        /// or smoothing still catching up)?
        public var wantsTime: Bool { renderer.wantsTime }

        /// Render more points; returns the rectangle that changed. The doc shows the stroke as
        /// committing it now would: with smoothing, the brush lags behind the pointer and catches
        /// up when the stroke ends, so that catch-up tail is drawn too (and redrawn on every step),
        /// and nothing new appears on release. Invalid coordinates reject the whole batch without
        /// changing the preview.
        @discardableResult
        public mutating func push(_ pts: [StrokePoint]) throws -> PixelRect {
            try ColorConvert.withCMYK(cmyk) { try pushInSpace(pts) }
        }

        private mutating func pushInSpace(_ pts: [StrokePoint]) throws -> PixelRect {
            try BrushCommands.checkCoords(pts, cmd)
            points += pts
            renderer.push(pts)
            if let symmetry {
                let reflected = symmetry.reflectedPasses(pts)
                for i in mirrors.indices where i < reflected.count {
                    mirrorDistinct[i] = mirrorDistinct[i] || SymmetryCommands.Axis.hasDistinctMirror(pts, reflected[i])
                    mirrors[i].push(reflected[i])
                }
            }
            // Edit the preview document in place (moved out, so its storage stays unique).
            var d = doc
            doc = LiveStroke.placeholder
            defer { doc = d }
            return try Channels.withTargetSurface(&d, layer: layer, params) { surf, _ in render(&surf) }
        }

        private mutating func render(_ surf: inout Surface) -> PixelRect {
            if mirrorDistinct.contains(true) {
                // The stroke and its distinct mirrors composite as one stroke, as the commit
                // merges them; only the tiles that changed are redrawn.
                let old = tail
                let passes = 1 + mirrorDistinct.filter { $0 }.count
                var live: UnionLive
                let full: Bool
                var dmg = PixelRect.empty
                if let u = unionLive {
                    live = u.0
                    full = u.1 != passes
                    unionLive = nil
                } else {
                    // Leaving the single-pass preview: take its smoothing tail back first.
                    if !old.isEmpty { surf.writeRegion(old, pre.readRegion(old)) }
                    live = UnionLive()
                    full = true
                    dmg = old
                }
                let idx = mirrors.indices.filter { mirrorDistinct[$0] }
                var passesR = [renderer] + idx.map { mirrors[$0] }
                dmg = dmg.union(StrokeRenderer.compositeUnionLive(&passesR, live: &live, full: full, pre: pre, target: &surf, selection: sel,
                                                                  lockTransparency: lock))
                renderer = passesR[0]
                for (k, i) in idx.enumerated() { mirrors[i] = passesR[k + 1] }
                tail = old.union(live.bounds)
                unionLive = (live, passes)
                return dmg
            }
            var dmg = PixelRect.empty
            let old = tail
            tail = .empty
            if !old.isEmpty {
                // Back to the stroke without the previous tail.
                surf.writeRegion(old, pre.readRegion(old))
                renderer.markDirty(old)
                dmg = old
            }
            dmg = dmg.union(renderer.composite(pre: pre, target: &surf, selection: sel, lockTransparency: lock, all: false))
            if var t = renderer.tailPreview() {
                tail = t.composite(pre: pre, target: &surf, selection: sel, lockTransparency: lock, all: false)
                dmg = dmg.union(tail)
            }
            return dmg
        }
    }
}
