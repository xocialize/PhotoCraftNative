// Live strokes for the retouching commands (AB-T-0299 item 2), as `BrushCommands.LiveStroke` is for the Brush: a
// stroke rendered while it is drawn, onto a copy of the active document, a batch of points at a time, so a preview
// costs what the new points cost instead of a rerun of the whole stroke. Offering the finished stroke to the session
// (`LiveRetouchStroke.offer`) lets its commit take these pixels, so the preview is the commit (AB-L-0280).
//
// - Smudge, Blur, Sharpen and Sponge (the sequential-dab tools): each push runs only the new dabs on a working copy
//   that grows with the stroke, and mixes the changed area back. What finishing the stroke would add (the first dab
//   of a click, Smoothing's catch-up) is drawn from a copy and taken back on the next push. The pixels equal the
//   command's (`dabCommand`); with Sample All Layers the composite is made as the working copy grows, piece by piece,
//   so a filter whose result depends on its region's edge could differ there.
// - Clone Stamp: PCPaint's `LiveRetouch` (the coverage so far through the source sampled from before the stroke).
//   Sampling more than the current layer, it samples the composite as the command does, a changed area at a time
//   (so the same filter caveat applies).
//
// Not live yet: the Healing Brush (its Poisson solve covers the whole stroke), Dodge and Burn (their per-pixel
// memory), Liquify.

import PCDocument
import PCFoundation
import PCPaint

/// A retouching stroke rendered while it is drawn: `paint.smudge`, `paint.blur`, `paint.sharpen`, `paint.sponge` or
/// `paint.cloneStamp`. Begin it with the command's params (their `points` are rendered), `push` more points as they
/// come, and show `doc`. To commit, run the command with the same params and every point pushed, after `offer`.
public struct LiveRetouchStroke {
    /// The commands with a live form.
    public static let commands: Set<String> = ["paint.smudge", "paint.blur", "paint.sharpen", "paint.sponge", "paint.cloneStamp"]

    /// The active document with the stroke so far.
    public private(set) var doc: Document
    let cmd: String
    let params: JSONValue
    let layer: LayerId?
    /// The document and revision the stroke started on.
    let base: (DocId, UInt64)
    /// Every point rendered so far, in order, as the command parses them.
    var points: [StrokePoint] = []
    var kind: Kind
    let cmyk: (any CMYKConverter)?
    /// Where Clone Stamp's composite sampler leaves the error it met (its push can't throw).
    let sampleFailure: SampleFailure?

    final class SampleFailure { var error: (any Error)? }

    enum Kind {
        case dabs(LiveDabs)
        case clone(PCPaint.LiveRetouch)
        /// While a push edits the stroke moved out of `kind` (so its buffers stay unique).
        case none
    }

    /// Start a live stroke of `cmd` (one of `commands`) with its params.
    public static func begin(_ s: Session, _ cmd: String, _ p: JSONValue) throws -> LiveRetouchStroke {
        guard commands.contains(cmd) else {
            throw EngineError.bad(cmd, "live retouching strokes are \(commands.sorted().joined(separator: ", "))")
        }
        if let why = RetouchCommands.hasPixelLayer(s, p) { throw EngineError.other(why) }
        guard let st = s.active else { throw EngineError.noDocument }
        let cmyk = DocumentCMYK.converter(for: st.doc)
        return try ColorConvert.withCMYK(cmyk) {
            let (stroke, id) = try RetouchCommands.parseBrush(s, p, cmd)
            var doc = st.doc
            let sel = doc.selection
            let kind: Kind
            var sampleFailure: SampleFailure?
            if cmd == "paint.cloneStamp" {
                let which = try RetouchCommands.sampleLayers(p, cmd)
                let mode = try RetouchCommands.blendParam(p, cmd)
                // The mapping the commit will resolve, without remembering the aligned anchor.
                let (map, _) = try CloneSourceCommands.resolve(s, p, first: RetouchCommands.firstPoint(stroke), cmd)
                let pre = try Channels.withTargetSurface(&doc, layer: id, p) { surf, lock in (surf, lock) }
                let paint: PCPaint.LiveRetouch.Paint
                if which == .current {
                    paint = .clone(source: pre.0, map: map)
                } else {
                    // The command's own sampler, so the composite is sampled as the commit samples it.
                    let sampler = RetouchCommands.Sampler(renderer: s.services.renderer, pre: st.doc, id: id, surf: pre.0, which: which)
                    let failure = SampleFailure()
                    paint = .sampled { r in
                        do { return try RetouchCommands.cloneSample(sampler, r, map, cmd) } catch {
                            failure.error = error
                            return nil
                        }
                    }
                    sampleFailure = failure
                }
                kind = .clone(PCPaint.LiveRetouch(brush: stroke.brush, layer: pre.0, paint: paint, mode: mode, selection: sel, lockTransparency: pre.1))
            } else {
                let (tool, _) = try RetouchCommands.DabTool.parse(s, cmd, p, stroke)
                let all = tool.samplesAllLayers && RetouchCommands.sampleAllLayers(p)
                let (pre, lock) = try Channels.withTargetSurface(&doc, layer: id, p) { surf, lock in (surf, lock) }
                kind = .dabs(LiveDabs(tool: tool, brush: stroke.brush, pre: pre, preDoc: st.doc, all: all, renderer: s.services.renderer,
                                      selection: sel, lockTransparency: lock))
            }
            var live = LiveRetouchStroke(doc: doc, cmd: cmd, params: p, layer: id, base: (st.doc.id, st.revision), kind: kind, cmyk: cmyk,
                                         sampleFailure: sampleFailure)
            _ = try live.pushInSpace(stroke.points)
            return live
        }
    }

    /// Everything the stroke has touched so far.
    public var bounds: PixelRect {
        switch kind {
        case .dabs(let d): d.bounds.union(d.tail)
        case .clone(let c): c.bounds
        case .none: .empty
        }
    }

    /// Does the stroke change with time while the pointer is held still (airbrush Build-up, or Smoothing catching up)?
    public var wantsTime: Bool {
        switch kind {
        case .dabs(let d): d.gen.wantsTime
        case .clone, .none: false
        }
    }

    /// Render more points; returns the rectangle of `doc` that changed. The doc shows the stroke as committing it now
    /// would. Invalid coordinates reject the whole batch without changing the preview.
    @discardableResult
    public mutating func push(_ pts: [StrokePoint]) throws -> PixelRect {
        try ColorConvert.withCMYK(cmyk) { try pushInSpace(pts) }
    }

    private mutating func pushInSpace(_ pts0: [StrokePoint]) throws -> PixelRect {
        // As the command parses them: position and pressure.
        let pts = pts0.map { StrokePoint($0.x, $0.y, $0.pressure) }
        try RetouchCommands.checkCoords(pts, cmd)
        points += pts
        // Edit the preview document in place (moved out, so its storage stays unique).
        var d = doc
        doc = BrushCommands.LiveStroke.placeholder
        defer { doc = d }
        return try Channels.withTargetSurface(&d, layer: layer, params) { surf, _ -> PixelRect in
            switch kind {
            case .dabs(var live):
                kind = .none
                defer { kind = .dabs(live) }
                return try live.push(pts, &surf)
            case .clone(var live):
                kind = .none
                defer { kind = .clone(live) }
                let dmg = live.push(pts)
                if let e = sampleFailure?.error { throw e }
                if !dmg.isEmpty { surf.writeRegion(dmg, live.surface.readRegion(dmg)) }
                return dmg
            case .none:
                return .empty
            }
        }
    }

    /// The stroke as its commit takes it over.
    public func intoCommit() throws -> LiveRetouchCommit {
        try ColorConvert.withCMYK(cmyk) {
            let (surface, b): (Surface, PixelRect)
            switch kind {
            case .dabs(let d): (surface, b) = try d.finished()
            case .clone(let c): (surface, b) = (c.surface, c.bounds)
            case .none: throw EngineError.other("internal error: the live stroke is being edited")
            }
            return LiveRetouchCommit(cmd: cmd, base: base, params: params, points: points, surface: surface, bounds: b)
        }
    }

    // MARK: Offering the stroke to its commit

    enum CommitKey: StateKey { static let defaultValue: LiveRetouchCommit? = nil }

    /// Offer a finished live stroke to the command that commits it: when that command's params, points and document
    /// revision match, it takes these pixels instead of running the stroke again.
    public static func offer(_ s: Session, _ live: LiveRetouchStroke) throws { s.state[CommitKey.self] = try live.intoCommit() }

    /// Withdraw an offer the command didn't take.
    public static func clearOffer(_ s: Session) { s.state[CommitKey.self] = nil }

    /// The offer `cmd` with `p` and `pts` takes (any offer is withdrawn).
    static func take(_ s: Session, _ cmd: String, _ p: JSONValue, _ pts: [StrokePoint]) -> LiveRetouchCommit? {
        let offered = s.state[CommitKey.self]
        s.state[CommitKey.self] = nil
        return offered.flatMap { $0.matches(s, cmd, p, pts) ? $0 : nil }
    }
}

/// A finished live retouching stroke offered to its own commit (`LiveRetouchStroke.offer`).
public struct LiveRetouchCommit: Sendable {
    let cmd: String
    let base: (DocId, UInt64)
    let params: JSONValue
    let points: [StrokePoint]
    let surface: Surface
    let bounds: PixelRect

    func matches(_ s: Session, _ cmd: String, _ p: JSONValue, _ pts: [StrokePoint]) -> Bool {
        guard let st = s.active else { return false }
        return self.cmd == cmd && st.doc.id == base.0 && st.revision == base.1 && points == pts
            && BrushCommands.LiveCommit.settings(p) == BrushCommands.LiveCommit.settings(params)
    }
}

/// The sequential-dab tools' live state: the dab generator, and a working copy of the target (and, with Sample All
/// Layers, of the composite) that grows to cover every dab and its halo.
struct LiveDabs {
    let cfg: Config
    var gen: DabGenerator
    var state: Working
    /// The dabs' bounds so far, and what the drawn tail (finishing the stroke now) covers.
    var bounds = PixelRect.empty
    var tail = PixelRect.empty

    /// What doesn't change during the stroke.
    struct Config {
        let fmt: PixelFormat
        let ctx: BrushContext
        let halo: Int32
        /// Blur's, Sharpen's or Sponge's per-dab edit (they keep nothing between dabs); Smudge keeps `Working.smudge`.
        let effect: RetouchCommands.DabEffect?
        let pre: Surface
        let preDoc: Document
        let renderer: EngineRenderer
        let sel: Surface?
        let lock: Bool
        let opacity: Float

        /// Where a dab reads and writes.
        func reach(_ ds: [Dab]) -> PixelRect { ds.reduce(PixelRect.empty) { $0.union(ctx.dabRect($1, dual: false).outset(by: halo)) } }

        /// Run `ds` on `st`, in order, as `dabCommand` does; returns the dabs' bounds.
        func run(_ ds: [Dab], _ st: inout Working) -> PixelRect {
            var b = PixelRect.empty
            for d in ds {
                let fp = ctx.footprint(d, index: st.count)
                st.count += 1
                b = b.union(ctx.dabRect(d, dual: false))
                if var v = st.visible {
                    // Sample All Layers: the effect runs on the composite, laid onto the layer under the dab.
                    st.visible = nil
                    apply(&v, fp, &st.smudge)
                    let r = fp.rect.intersect(st.work.rect)
                    if !r.isEmpty {
                        for y in r.y0..<r.y1 {
                            for x in r.x0..<r.x1 where fp.at(x, y) > 0 {
                                let src = v.px(x, y)
                                st.work.withPixel(x, y) { px in for (c, val) in src.enumerated() { px[c] = val } }
                            }
                        }
                    }
                    st.visible = v
                } else {
                    apply(&st.work, fp, &st.smudge)
                }
            }
            return b
        }

        func apply(_ work: inout Region, _ fp: Footprint, _ smudge: inout Smudge?) {
            if smudge != nil { smudge!.dab(&work, fp) } else { effect?(&work, fp) }
        }

        /// The pre-stroke pixels over `rect` mixed with `work`'s, at the stroke's opacity and the selection.
        func mix(_ surf: inout Surface, _ rect: PixelRect, _ work: Region) {
            if rect.isEmpty { return }
            PCPaint.Retouch.mixBack(&surf, orig: Region.read(pre, rect), work: work, rect: rect, opacity: opacity, selection: sel,
                                    lockTransparency: lock)
        }

        /// `st` grown to cover `need`: the new part is the pre-stroke pixels (and composite), as no dab has reached it.
        /// It grows by a margin, so a stroke grows it now and then rather than at every dab.
        func grow(_ st: inout Working, _ need: PixelRect) throws {
            let old = st.work.rect
            if need.isEmpty || (!old.isEmpty && old.contains(need)) { return }
            let side = old.isEmpty ? 0 : max(old.width, old.height)
            let grown = need.outset(by: Int32(max(64, side / 4)))
            let nr = old.isEmpty ? grown : old.union(grown)
            let pre = pre
            st.work = Self.regrown(st.work, nr) { Region.read(pre, $0) }
            if let v = st.visible {
                let (doc, fmt, renderer) = (preDoc, fmt, renderer)
                var failure: (any Error)?
                st.visible = Self.regrown(v, nr) { r in
                    do { return try RetouchCommands.compositeRegion(renderer, doc, nil, .all, r, fmt) } catch {
                        failure = error
                        return Region(rect: r, ch: fmt.channels)
                    }
                }
                if let failure { throw failure }
            }
        }

        /// `r` over `nr` (which holds `r.rect`): `r`'s pixels, and `fill`'s for the rest, a strip at a time.
        static func regrown(_ r: Region, _ nr: PixelRect, _ fill: (PixelRect) -> Region) -> Region {
            var out = Region(rect: nr, ch: r.ch)
            let o = r.rect
            let strips = o.isEmpty ? [nr] : [PixelRect(x0: nr.x0, y0: nr.y0, x1: nr.x1, y1: o.y0), PixelRect(x0: nr.x0, y0: o.y1, x1: nr.x1, y1: nr.y1),
                                             PixelRect(x0: nr.x0, y0: o.y0, x1: o.x0, y1: o.y1), PixelRect(x0: o.x1, y0: o.y0, x1: nr.x1, y1: o.y1)]
            for strip in strips where !strip.isEmpty { copy(fill(strip), into: &out) }
            if !o.isEmpty { copy(r, into: &out) }
            return out
        }

        /// Copy `src` into `dst` where they overlap.
        static func copy(_ src: Region, into dst: inout Region) {
            let r = src.rect.intersect(dst.rect)
            if r.isEmpty { return }
            let n = dst.ch, w = r.width * n
            for y in r.y0..<r.y1 {
                let s = src.index(r.x0, y) * n, d = dst.index(r.x0, y) * n
                dst.data.withUnsafeMutableBufferPointer { db in
                    src.data.withUnsafeBufferPointer { sb in (db.baseAddress! + d).update(from: sb.baseAddress! + s, count: w) }
                }
            }
        }
    }

    /// What the dabs have done so far.
    struct Working {
        var work: Region
        var visible: Region?
        var smudge: Smudge?
        /// Dabs run so far (each footprint's index).
        var count = 0
    }

    init(tool: RetouchCommands.DabTool, brush: BrushSettings, pre: Surface, preDoc: Document, all: Bool, renderer: EngineRenderer,
         selection: Surface?, lockTransparency: Bool) {
        let fmt = pre.format
        let smudge = tool.smudgeState(fmt)
        cfg = Config(fmt: fmt, ctx: BrushContext(brush), halo: tool.halo, effect: smudge == nil ? tool.effect(fmt, brush.spacing) : nil, pre: pre,
                     preDoc: preDoc, renderer: renderer, sel: selection, lock: lockTransparency, opacity: brush.opacity)
        gen = DabGenerator(brush: brush, zoom: 1)
        state = Working(work: Region(rect: .empty, ch: fmt.channels), visible: all ? Region(rect: .empty, ch: fmt.channels) : nil, smudge: smudge)
    }

    /// Push points: the new dabs run on the working copy, and `surf` shows them, with what finishing would add.
    mutating func push(_ pts: [StrokePoint], _ surf: inout Surface) throws -> PixelRect {
        var dmg = tail
        if !tail.isEmpty { cfg.mix(&surf, tail, state.work) }
        tail = .empty
        var ds: [Dab] = [], dual: [Dab] = []
        gen.push(pts, &ds, &dual)
        try cfg.grow(&state, cfg.reach(ds))
        let r = cfg.run(ds, &state)
        bounds = bounds.union(r)
        cfg.mix(&surf, r, state.work)
        dmg = dmg.union(r)
        // The tail, from a copy of the part of the working copy it reaches.
        var g = gen
        var td: [Dab] = []
        g.finish(&td, &dual)
        if !td.isEmpty {
            let need = cfg.reach(td)
            try cfg.grow(&state, need)
            var t = Working(work: state.work.crop(need), visible: state.visible?.crop(need), smudge: state.smudge, count: state.count)
            tail = cfg.run(td, &t)
            cfg.mix(&surf, tail, t.work)
            dmg = dmg.union(tail)
        }
        return dmg
    }

    /// The target as the command commits the stroke: every dab, the ones finishing adds included, mixed back over
    /// the dabs' bounds; and those bounds.
    func finished() throws -> (Surface, PixelRect) {
        var g = gen, st = state
        var td: [Dab] = [], dual: [Dab] = []
        g.finish(&td, &dual)
        try cfg.grow(&st, cfg.reach(td))
        let b = bounds.union(cfg.run(td, &st))
        var surf = cfg.pre
        cfg.mix(&surf, b, st.work)
        return (surf, b)
    }
}
