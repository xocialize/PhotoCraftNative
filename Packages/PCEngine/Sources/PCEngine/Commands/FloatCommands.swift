// Port of photocraft-engine (crates/engine/src/float_cmds.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Floating selection: the selected pixels of a layer cut out and moved as a piece, without
// touching the document until the piece is dropped.
//
// - `select.float {"dx","dy","copy"}` cuts the selected pixels of the active layer into a floating
//   piece (the first time; `copy` leaves them and floats a duplicate) and moves it by whole pixels.
//   Further calls move the same piece. The Move tool and the marquee / lasso ⌘-drags move this way.
// - `select.drop` drops the piece into its layer and moves the selection with it: one history step.
// - Any other command drops the piece first (a dispatch hook), except Undo, which puts it back.
//
// While floating the document is unchanged; `displayed` gives the document with the piece at its
// offset, for the canvas.

import Foundation
import PCDocument
import PCFoundation

public enum FloatCommands: CommandModule {
    public static let name = "float_cmds"
    static let m = "float_cmds"

    public static func register(into r: inout CommandRegistry) {
        r.add(CommandSpec("select.float", "Float Selection",
                          params: #"{"dx":px=0,"dy":px=0,"copy":bool=false,"target":"pixels"|"mask"="pixels" (mask: float the selected part of the layer's mask, the hole takes the background colour)} → {layer, offset} (cuts the selected pixels of the active layer into a floating piece the first time, or with copy leaves them and floats a duplicate; on the Background the hole takes the background colour; then moves it by whole pixels; dropped by select.drop or any other command, put back by edit.undo)"#,
                          module: m, enabled: canFloat, run: float))
        r.add(CommandSpec("select.drop", "Drop Floating Selection",
                          params: #"{} → {dropped, offset} (drops the floating piece into its layer and moves the selection with it: one history step)"#,
                          module: m, enabled: { s, _ in s.active == nil ? "no document" : nil }) { s, _ in try dropFloating(s) })
        // photocraft `Session::dispatch` → `float_cmds::before_command`.
        r.hooks.before.append { s, id, _ in try beforeCommand(s, id) }
    }

    /// A layer split by its selection: the layer with the selected pixels cut out, and the cut
    /// pixels (cropped to the selection) (photocraft `CutParts`).
    public struct CutParts: Sendable {
        public let layer: LayerId
        let rest: Surface
        let piece: Surface
        /// The pieces are the layer's mask (`"target":"mask"`), not its pixels.
        let mask: Bool

        /// Splits `layer` of `doc` by its selection. With `copy` the selected pixels stay too.
        /// Without, they leave a transparent hole, or on the Background (and in a mask) one filled
        /// with `background`.
        public init(_ doc: Document, layer: LayerId, copy: Bool, background: SIMD4<Float>, mask: Bool) throws {
            guard let sel = doc.selection else { throw EngineError.other("no selection") }
            guard let l = doc.layer(layer) else { throw EngineError.noLayer(layer) }
            let surf: Surface
            if mask {
                guard let mk = l.mask else { throw EngineError.other("the layer has no mask") }
                surf = mk.surface
            } else {
                guard case .raster(let s) = l.content else { throw EngineError.other("the layer has no pixels to move") }
                surf = s
            }
            let fmt = surf.format
            let withAlpha = PixelFormat(mode: fmt.mode, sample: fmt.sample, alpha: true)
            let full = fmt == withAlpha ? surf : surf.convertedAny(to: withAlpha)
            // A mask has no alpha: it keeps its format, and the cut leaves background colour.
            var rest = mask ? surf : full
            var piece = Surface(format: withAlpha)
            let fill = !copy && (mask || doc.isBackground(layer))
            // A mask's untouched pixels (its default) move too, so take the whole canvas.
            let b = sel.contentBounds.intersect(mask ? doc.bounds : surf.contentBounds)
            if !b.isEmpty {
                let n = withAlpha.channels, a = n - 1
                var rp = full.readRegion(b)
                var pp = rp
                let cov = sel.coverage(b)
                for i in 0..<b.area {
                    let k = cov[i]
                    if k <= 0 {
                        for c in 0..<n { pp[i * n + c] = 0 }
                    } else {
                        pp[i * n + a] *= k
                    }
                    if !copy && !fill { rp[i * n + a] *= 1 - k }
                }
                if !mask { rest.writeRegion(b, rp) }
                if fill { Pixels.fillSurface(&rest, b, color: background, selection: sel, lockTransparency: true) }
                rest.prune()
                piece.writeRegion(b, pp)
                piece.prune()
            }
            self.layer = layer
            self.rest = rest
            self.piece = piece
            self.mask = mask
        }

        /// `doc` with the piece moved by whole pixels (dx, dy) over the cut-out layer.
        public func moved(_ doc: Document, _ dx: Int32, _ dy: Int32) throws -> Document {
            var d = doc
            try place(&d, dx, dy)
            return d
        }

        /// Puts the piece, moved by (dx, dy), over the cut-out layer (or mask) of `doc`.
        func place(_ doc: inout Document, _ dx: Int32, _ dy: Int32) throws {
            guard let l = doc.layer(layer) else { throw EngineError.noLayer(layer) }
            var out = rest
            let moved = piece.shifted(dx: dx, dy: dy)
            if mask {
                guard l.mask != nil else { throw EngineError.other("the layer has no mask") }
                FloatCommands.compositeOverMask(&out, moved)
                doc.updateLayer(layer) { l in l.mask?.surface = out }
            } else {
                guard case .raster = l.content else { throw EngineError.other("the layer has no pixels to move") }
                FloatCommands.compositeOver(&out, moved)
                doc.withRaster(of: layer) { $0 = out }
            }
        }
    }

    /// Source-over of `top` onto `dst` (same format, straight alpha) (photocraft
    /// `transform_cmds::composite_over`).
    static func compositeOver(_ dst: inout Surface, _ top: Surface) {
        let b = top.contentBounds
        if b.isEmpty || dst.format != top.format { return }
        let n = dst.format.channels, a = n - 1
        let t = top.readRegion(b)
        var d = dst.readRegion(b)
        for i in 0..<b.area {
            let o = i * n
            let ta = t[o + a], da = d[o + a]
            let oa = ta + da * (1 - ta)
            if oa > 0 {
                for c in 0..<a { d[o + c] = (t[o + c] * ta + d[o + c] * da * (1 - ta)) / oa }
            }
            d[o + a] = oa
        }
        dst.writeRegion(b, d)
    }

    /// Normal 100 % of a gray+alpha piece over an alpha-less mask (photocraft
    /// `fill_cmds::composite_over` on a mask).
    static func compositeOverMask(_ dst: inout Surface, _ top: Surface) {
        let b = top.contentBounds
        if b.isEmpty { return }
        let src = top.readRGBA(b)
        let dn = dst.format.channels
        var d = dst.readRegion(b)
        for i in 0..<b.area {
            let s = src[i]
            let g = 0.299 * s.x + 0.587 * s.y + 0.114 * s.z
            for c in 0..<dn { d[i * dn + c] += (g - d[i * dn + c]) * s.w }
        }
        dst.writeRegion(b, d)
        dst.prune()
    }

    /// A piece floating `offset` whole pixels from where it was cut, over document `revision`.
    public struct Floating: Sendable {
        public let layer: LayerId
        public var offset: SIMD2<Int32>
        public let revision: UInt64
        public let parts: CutParts
    }

    /// The per-document floating piece (photocraft `DocState::floating`).
    public enum FloatingKey: StateKey { public static let defaultValue: Floating? = nil }

    /// The floating piece of `st`, if it is still valid (the document hasn't changed under it).
    public static func floating(_ st: DocState) -> Floating? {
        guard let f = st.view[FloatingKey.self], f.revision == st.revision, st.doc.selection != nil else { return nil }
        return f
    }

    /// The document as shown while a piece floats `extra` further than its offset; nil when
    /// nothing floats.
    public static func displayed(_ st: DocState, extra: SIMD2<Int32> = .zero) -> Document? {
        guard let f = floating(st) else { return nil }
        return try? f.parts.moved(st.doc, f.offset.x &+ extra.x, f.offset.y &+ extra.y)
    }

    static func intParam(_ p: JSONValue, _ key: String) -> Int32 {
        guard let v = p[key]?.doubleValue, v.isFinite else { return 0 }
        return Int32(min(max(v.rounded(), -1e7), 1e7))
    }

    static let canFloat: CommandEnabled = { s, _ in
        guard let st = s.active else { return "no document" }
        if floating(st) != nil { return nil }
        if st.doc.selection == nil { return "there is no selection" }
        guard let l = st.activeLayer.flatMap({ st.doc.layer($0) }) else { return "no active layer" }
        guard case .raster = l.content else { return "the active layer has no pixels to move" }
        if lockedForFloat(st.doc, l) { return "layer \"\(l.name)\" is locked" }
        return nil
    }

    /// Do `l`'s locks (its own, or a locked group's) stop its selected pixels floating? The
    /// Background is position-locked, but its selected pixels move (Photoshop).
    public static func lockedForFloat(_ doc: Document, _ l: Layer) -> Bool {
        let locks = doc.effectiveLocks(l.id)
        return locks.all || (locks.position && !doc.isBackground(l.id))
    }

    static func float(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let dx = intParam(p, "dx"), dy = intParam(p, "dy")
        let copy = p["copy"]?.boolValue ?? false
        let background = s.tools.background
        return try s.updateActive { st -> JSONValue in
            if floating(st) == nil {
                guard let layer = st.activeLayer else { throw EngineError.other("no active layer") }
                let parts = try CutParts(st.doc, layer: layer, copy: copy, background: background, mask: LayerOps.isMaskTarget(p))
                st.view[FloatingKey.self] = Floating(layer: layer, offset: .zero, revision: st.revision, parts: parts)
            }
            guard var f = st.view[FloatingKey.self] else { throw EngineError.noDocument }
            f.offset = SIMD2(Int32(clamping: Int64(f.offset.x) + Int64(dx)), Int32(clamping: Int64(f.offset.y) + Int64(dy)))
            st.view[FloatingKey.self] = f
            return ["layer": .id(f.layer), "offset": [.int(Int(f.offset.x)), .int(Int(f.offset.y))]]
        }
    }

    static func clearFloating(_ s: Session) {
        if s.active?.view[FloatingKey.self] != nil { try? s.updateActive { $0.view[FloatingKey.self] = nil } }
    }

    /// Drops the floating piece into its layer and moves the selection with it (one step).
    @discardableResult
    public static func dropFloating(_ s: Session) throws -> JSONValue {
        guard let st = s.active else { return ["dropped": false] }
        guard let f = floating(st) else {
            clearFloating(s)
            return ["dropped": false]
        }
        clearFloating(s)
        let dx = f.offset.x, dy = f.offset.y
        if dx == 0 && dy == 0 { return ["dropped": true, "offset": [0, 0]] }
        try s.edit("Move") { doc, _ in
            try f.parts.place(&doc, dx, dy)
            doc.selection = doc.selection.map { $0.shifted(dx: dx, dy: dy) }
        }
        return ["dropped": true, "offset": [.int(Int(dx)), .int(Int(dy))]]
    }

    /// Commands that leave a floating piece floating: its own, and ones that don't touch documents.
    static func keepsFloating(_ id: String) -> Bool {
        id == "select.float" || id == "select.drop" || ["view.", "window.", "help.", "prefs."].contains { id.hasPrefix($0) }
    }

    /// Before any command: Undo puts a floating piece back (and is used up: returns its result);
    /// every other command but the floating ones drops it first.
    static func beforeCommand(_ s: Session, _ id: String) throws -> JSONValue? {
        guard let st = s.active else { return nil }
        if floating(st) == nil {
            clearFloating(s)
            return nil
        }
        switch id {
        case "edit.undo", "edit.stepBackward":
            clearFloating(s)
            return ["floating": "returned"]
        case _ where keepsFloating(id):
            return nil
        default:
            try dropFloating(s)
            return nil
        }
    }
}
